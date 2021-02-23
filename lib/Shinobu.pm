package Shinobu;

# LANraragi File Watcher.
#  Uses inotify watches to keep track of filesystem happenings.
#  My main tasks are:
#
#    Tracking all files in the content folder and making sure they're sync'ed with the database
#    Automatically cleaning the temporary folder when it reaches a certain size
#

use strict;
use warnings;
use utf8;
use feature qw(say);
use Cwd;

use FindBin;
use Parallel::Loops;
use Sys::CpuAffinity;
use Storable qw(lock_store);
use Mojo::JSON qw(to_json);

#As this is a new process, reloading the LRR libs into INC is needed.
BEGIN { unshift @INC, "$FindBin::Bin/../lib"; }

use Mojolicious;
use File::ChangeNotify;
use File::Find;
use File::Basename;
use Encode;

use LANraragi::Utils::Database qw(invalidate_cache compute_id);
use LANraragi::Utils::TempFolder qw(get_temp clean_temp_partial);
use LANraragi::Utils::Logging qw(get_logger);
use LANraragi::Utils::Generic qw(is_archive split_workload_by_cpu);

use LANraragi::Model::Config;
use LANraragi::Model::Plugins;
use LANraragi::Utils::Plugins;    # Needed here since Shinobu doesn't inherit from the main LRR package
use LANraragi::Model::Search;     # idem

# Logger and Database objects
my $logger = get_logger( "Shinobu", "shinobu" );

#Subroutine for new and deleted files that takes inotify events
my $inotifysub = sub {
    my $e    = shift;
    my $name = $e->path;
    my $type = $e->type;
    $logger->debug("Received inotify event $type on $name");

    if ( $type eq "create" || $type eq "modify" ) {
        new_file_callback($name);
    }

    if ( $type eq "delete" ) {
        deleted_file_callback($name);
    }

};

sub initialize_from_new_process {

    my $userdir = LANraragi::Model::Config->get_userdir;

    $logger->info("Shinobu File Watcher started.");
    $logger->info( "Working dir is " . cwd );

    update_filemap();
    $logger->info("Adding watcher to content folder $userdir");

    # Add watcher to content directory
    my $contentwatcher = File::ChangeNotify->instantiate_watcher(
        directories     => [$userdir],
        filter          => qr/\.(?:zip|rar|7z|tar|tar\.gz|lzma|xz|cbz|cbr|pdf|epub|)$/,
        follow_symlinks => 1,
        exclude         => [ 'thumb', '.' ],                                              #excluded subdirs
    );

    my $class = ref($contentwatcher);
    $logger->debug("Watcher class is $class");

    # Add watcher to tempfolder
    my $tempwatcher = File::ChangeNotify->instantiate_watcher( directories => [ get_temp() ] );

    # manual event loop
    $logger->info("All done! Now dutifully watching your files. ");

    while (1) {

        # Check events on files
        for my $event ( $contentwatcher->new_events ) {
            $inotifysub->($event);
        }

        # Check the current temp folder size and clean it if necessary
        for my $event ( $tempwatcher->new_events ) {
            clean_temp_partial();
        }

        sleep 2;
    }
}

# Update the filemap. This acts as a masterlist of what's in the content directory.
# This computes IDs for all new archives and henceforth can get rather expensive!
sub update_filemap {

    $logger->info("Scanning content folder for changes...");
    my $redis = LANraragi::Model::Config->get_redis;

    # Clear hash
    my $dirname = LANraragi::Model::Config->get_userdir;
    my @files;

    # Get all files in content directory and subdirectories.
    find(
        {   wanted => sub {
                return if -d $_;    #Directories are excluded on the spot
                return unless is_archive($_);
                push @files, $_;    #Push files to array
            },
            no_chdir    => 1,
            follow_fast => 1
        },
        $dirname
    );

    # Cross-check with filemap to get recorded files that aren't on the FS, and new files that aren't recorded.
    my @filemapfiles = $redis->exists("LRR_FILEMAP") ? $redis->hkeys("LRR_FILEMAP") : ();

    my %filemaphash = map { $_ => 1 } @filemapfiles;
    my %fshash      = map { $_ => 1 } @files;

    my @newfiles     = grep { !$filemaphash{$_} } @files;
    my @deletedfiles = grep { !$fshash{$_} } @filemapfiles;

    $logger->info( "Found " . scalar @newfiles . " new files." );
    $logger->info( scalar @deletedfiles . " files were found on the filemap but not on the filesystem." );

    # Delete old files from filemap
    foreach my $deletedfile (@deletedfiles) {
        $logger->debug("Removing $deletedfile from filemap.");
        $redis->hdel( "LRR_FILEMAP", $deletedfile ) || $logger->warn("Couldn't delete previous filemap data.");
    }

    $redis->quit();

    # Now that we have all new files, process them...with multithreading!
    my $numCpus = Sys::CpuAffinity::getNumCpus();
    my $pl      = Parallel::Loops->new($numCpus);

    $logger->debug("Number of available cores for processing: $numCpus");
    my @sections = split_workload_by_cpu( $numCpus, @newfiles );

    # Eval the parallelized file crawl to avoid taking down the entire process in case one of the forked processes dies
    eval {
        $pl->foreach(
            \@sections,
            sub {
                # This sub "magically" executed in parallel forked child processes
                foreach my $file (@$_) {

                    # Individual files are also eval'd so we can keep scanning
                    eval { add_to_filemap($file); };

                    if ($@) {
                        $logger->error("Error scanning $file: $@");
                    }
                }
            }
        );
    };

    if ($@) {
        $logger->error("Error while scanning content folder: $@");
    }
}

sub add_to_filemap {

    my ($file) = shift;

    if ( is_archive($file) ) {

        my $redis = LANraragi::Model::Config->get_redis;
        $logger->debug("Adding $file to Shinobu filemap.");

        #Freshly created files might not be complete yet.
        #We have to wait before doing any form of calculation.
        while (1) {
            last unless -e $file;    # Sanity check to avoid sticking in this loop if the file disappears
            last if open( my $handle, '<', $file );
            $logger->debug("Waiting for file to be openable");
            sleep(1);
        }

        # Wait for file to be more than 512 KBs or bailout after 5s and assume that file is smaller
        my $cnt = 0;
        while (1) {
            last if ( ( ( -s $file ) >= 512000 ) || $cnt >= 5 );
            $logger->debug("Waiting for file to be fully written");
            sleep(1);
            $cnt++;
        }

        #Compute the ID of the archive and add it to the hash
        my $id = "";
        eval { $id = compute_id($file); };

        if ($@) {
            $logger->error("Couldn't open $file for ID computation: $@");
            $logger->error("Giving up on adding it to the filemap.");
            return;
        }

        $logger->debug("Computed ID is $id.");

        # If the id already exists on the server, throw a warning about duplicates
        if ( $redis->hexists( "LRR_FILEMAP", $file ) ) {

            my $id = $redis->hget( "LRR_FILEMAP", $file );

            $logger->debug( "$file was logged again but is already in the filemap, duplicate inotify events? "
                  . "Cleaning cache just to make sure" );

            invalidate_cache();
            $redis->quit();
            return;

        } else {
            $redis->hset( "LRR_FILEMAP", $file, $id );    # raw FS path so no encoding/decoding whatsoever
        }

        # Filename sanity check
        if ( $redis->exists($id) ) {

            my $filecheck = $redis->hget( $id, "file" );

            #Update the real file path and title if they differ from the saved one
            #This is meant to always track the current filename for the OS.
            unless ( $file eq $filecheck ) {
                $logger->debug("File name discrepancy detected between DB and filesystem!");
                $logger->debug("Filesystem: $file");
                $logger->debug("Database: $filecheck");
                my ( $name, $path, $suffix ) = fileparse( $file, qr/\.[^.]*/ );
                $redis->hset( $id, "file", $file );
                $redis->hset( $id, "name", encode_utf8($name) );
                $redis->wait_all_responses;
                invalidate_cache();
            }
        } else {

            # Add to Redis if not present beforehand
            add_new_file( $id, $file, $redis );
            invalidate_cache();
        }

        $redis->quit();
    }
}

# Only handle new files. As per the ChangeNotify doc, it
# "handles the addition of new subdirectories by adding them to the watch list"
sub new_file_callback {
    my $name = shift;

    unless ( -d $name ) {

        eval { add_to_filemap($name); };

        if ($@) {
            $logger->error("Error while handling new file: $@");
        }
    }
}

#Deleted files are simply dropped from the filemap.
#Deleted subdirectories trigger deleted events for every file deleted.
sub deleted_file_callback {
    my $name = shift;
    $logger->info("$name was deleted from the content folder!");

    unless ( -d $name ) {

        my $redis = LANraragi::Model::Config->get_redis;

        # Prune file from filemap
        $redis->hdel( "LRR_FILEMAP", $name );

        eval { invalidate_cache(); };

        $redis->quit();
    }
}

sub add_new_file {

    my ( $id, $file, $redis ) = @_;
    $logger->info("Adding new file $file with ID $id");

    eval {
        LANraragi::Utils::Database::add_archive_to_redis( $id, $file, $redis );

        #AutoTagging using enabled plugins goes here!
        if ( LANraragi::Model::Config->enable_autotag ) {
            LANraragi::Model::Plugins::exec_enabled_plugins_on_file($id);
        }
    };

    if ($@) {
        $logger->error("Error while adding file: $@");
    }
}

__PACKAGE__->initialize_from_new_process unless caller;

1;
