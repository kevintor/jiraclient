
package LSFSpool;

use strict;
use warnings;

require Exporter;
use AutoLoader qw(AUTOLOAD);

our @ISA = qw(Exporter);

# Items to export into callers namespace by default. Note: do not export
# names by default without a very good reason. Use EXPORT_OK instead.
# Do not simply export all your public functions/methods/constants.

# This allows declaration: use LSFSpool ':all';
# If you do not need this, moving things directly into @EXPORT or @EXPORT_OK
# will save memory.
our %EXPORT_TAGS = ( 'all' => [ qw(
) ] );
our @EXPORT_OK = ( @{ $EXPORT_TAGS{'all'} } );
our @EXPORT = qw();
our $VERSION = '0.4.10';

use English;
use Data::Dumper;
use Carp;
use Error qw(:try);

# Path handling
use Cwd 'abs_path';
# For DB SQLite
use DBI;
# For option parsing.
use Getopt::Std;
# For basename and dirname
use File::Basename;
# For find like functionality
require File::Find::Rule;

# For the Suite of valid commands
use LSFSpool::Suite;
# For the Cache of completed work
use LSFSpool::Cache;

# For LSF interaction.
use LSF::Job;

# -- Subroutines
#
sub new {
  my $self = {
    configfile => undef,
    stopflag => "LSFSTOP-$$",
    dryrun => 0,
    debug => 0,
    buildonly => 0,
    cachefile => undef,
    logdir => undef,
    startpos => undef,
    endpos => undef,
    bsub => undef,
    bjobs => undef,
    bqueues => undef,
    logfile => undef,
    logfh => undef,
    suite => undef,
    dbh => undef,
    cache => new LSFSpool::Cache,
    config  => {},
  };
  bless $self, 'LSFSpool';
  $self->{cache}->{parent} = $self;
  # This is a bit of a hack to get Cache to use the
  # same logging/debugging as LSFSpool.  Should probably
  # have a Utility library or something.
  return $self;
}

sub logger {
  # Simple logging where logfile is set during startup
  # to either a file handle or STDOUT.
  my $self = shift;
  my $fh = $self->{logfh};
  throw Error::Simple("no logfile defined, run prepare_logger\n")
    if (! defined $fh);
  print $fh localtime() . ": @_";
}

sub debug {
  # Simple debugging.
  my $self = shift;
  if ($self->{debug}) {
    $self->logger("DEBUG: @_");
  }
}

sub parsefile {
  # Parse a file name argument and return parameters to be used
  # in an LSF bsub command.
  my $self = shift;
  my $jobname = shift;
  $jobname = abs_path($jobname);
  $self->debug("parsefile($jobname)\n");

  # Set the job array number based on the digits in the file name.
  # We do this for convenient accounting.
  my $number;
  # FIXME: this sets number = 1 wrongly
  if ( $jobname =~ m/^.*-(\d+)$/ ) {
    $number = $1;
  } else {
    throw Error::Simple("filename does not contain a number\n");
  }

  my $inputfile = basename $jobname; # query file is the file
  my $spooldir = dirname $jobname; # jobname is parent dir
  my $jobarray = basename $spooldir . "\[$number\]";

  $self->debug("$spooldir,$inputfile,$jobarray\n");
  return ($spooldir,$inputfile,$jobarray);
}

sub parsedir {
  # Parse a directory name argument and return parameters to be used
  # in an LSF bsub command.
  my $self = shift;
  my $jobname = shift;
  $jobname = abs_path($jobname);
  my $inputfile = basename $jobname . '-\$LSB_JOBINDEX';
  my $spooldir = $jobname;

  my @inputfiles = grep(/$jobname/,$self->findfiles($jobname));
  my $count = grep(!/-output/,@inputfiles);
  my $jobarray = basename $jobname . "\[1-$count\]";

  throw Error::Simple("spool $jobname contains no files") if ($count == 0);

  return ($spooldir,$inputfile,$jobarray);
}

sub bsub {
  # Submit an LSF job using bsub.
  # Note that LSF::Job is insufficient for submission as it does not
  # support all the arguments we'd like to use.
  my $self = shift;

  # - If the first argument is a file, create a job array of one value
  # and bsub the one file.
  # - If it's a directory, build an array of N values for all files.
  my $jobname = shift;

  # Optional arguments for wait option -K and priority.
  my $wait = (shift) ? 1 : 0;
  my $prio = (shift) ? 1 : 0;

  $self->debug("bsub($jobname,$wait,$prio)\n");

  my $spooldir;
  my $inputfile;
  my $jobarray;

  # Examine our argument and determine job parameters.
  if (-f $jobname) {
    ($spooldir,$inputfile,$jobarray) = $self->parsefile($jobname);
  } elsif (-d $jobname) {
    ($spooldir,$inputfile,$jobarray) = $self->parsedir($jobname);
  } else {
    throw Error::Simple("argument is not a file or directory: $jobname");
  }

  throw Error::Simple("spool contains an invalid file or directory: $jobname\n")
    if (! defined $spooldir);

  chdir $spooldir or throw Error::Simple("cannot chdir to $spooldir: $!");

  # Note here the use of -E for a "pre-exec" job, where we have bsub re-execute
  # our self to check to see if there's already full output for a particular
  # job index.  This allows for easy re-submission on previous failure.
  my $command = ($wait) ? "$self->{bsub} -K " : "$self->{bsub} ";

  # FIXME: use MAX_USER_PRIO or a configurable
  $command .= ($prio) ? '-sp 300 ' : '';

  # Set -u option for bsub, but be careful, if you're submitting
  # thousands of jobs, your INBOX will become quite full.
  if (exists $self->{config}->{email} and
      length($self->{config}->{email}) > 0) {
    $command .= "-u $self->{config}->{email} ";
  }

  # Append optional bsubargs string
  if (exists $self->{config}->{bsubargs}) {
    $command .= "$self->{config}->{bsubargs} ";
  }

  # Append the queue and the jobarray we've constructed.
  $command .= "-q $self->{config}->{queue} -J $jobarray ";

  # LSF post-exec moves output file to destination directory.
  $command .= "-Ep \"mv -f /tmp/$inputfile-output $spooldir/$inputfile-output;\" ";

  # Append logging.
  if ( defined $self->{logdir} ) {
    $command .= '-e ' . $self->{logdir} . "/$jobarray.%I.%J.err ";
    $command .= '-o ' . $self->{logdir} . "/$jobarray.%I.%J.out ";
  }

  # This is the command, as per the Suite called.
  $command .= $self->{suite}->action($spooldir,$inputfile) . " ";

  # Dry run mode shows you what *would* be submitted.
  $self->logger($command . "\n");
  return 0 if ($self->{dryrun});

  # Exec the command and get the jobid.
  open(COMMAND,"$command 2>&1 |") or throw Error::Simple("failed to run bsub: $!");
  my $output = <COMMAND>;
  close(COMMAND);
  my $rc = $? >> 8;
  if ($rc == 255) {
    $self->logger("bsub exits non-zero: $rc: perhaps queue is closed?\n");
    return -1;
  } elsif ($rc) {
    $self->logger("bsub exits non-zero: $rc\n");
    return -1;
  }
  $output =~ /^.* \<(\d+)\> .*$/;
  my $jobid = $1;

  $self->logger("submitted job id $jobid\n");
  return $jobid;
}

sub check_cwd {
  # The path argument should fit a naming scheme
  # starting with the top level spool name.
  my $self = shift;
  my $jobname = shift;
  $self->debug("check_cwd($jobname)\n");

  $self->logger("examine spool directory: $jobname\n");
  my @list = map { basename($_) } $self->findfiles($jobname);
  my $dir = basename $jobname;
  my @oddfiles = grep(!/^(|\w+-)$dir.*(-\d+)+(|-output)$/,@list);
  if (scalar @oddfiles != 0) {
    throw Error::Simple("spool directory '$dir' has unexpected files: @oddfiles");
  }

  @list = map { basename($_) } $self->finddirs($jobname);
  my @odddirs = grep(!/^(|\w+-)$dir.*(-\d+)+$/,@list);
  if (scalar @odddirs != 0) {
    throw Error::Simple("spool directory '$dir' has unexpected directories: @odddirs");
  }
  return 1;
}

sub check_running {
  # Ask LSF if any jobs named for this spool are running.
  # Both single file or directory are possible.
  my $self = shift;
  my $jobname = shift;
  $self->debug("check_running($jobname)\n");

  if (-f $jobname) {
    $jobname =~ /^(.*)-(\d+)$/;
    $jobname = $1;
    my $number = $2;
    $jobname = basename $jobname . "\[$number\]";
  } else {
    $jobname = basename $jobname;
  }
  LSF::Job->PrintOutput(0);
  LSF::Job->PrintError(0);
  my @jobs = LSF::Job->jobs( -J => $jobname );
  $self->logger(scalar @jobs . " " . basename $jobname . " jobs running\n");
  return scalar @jobs;
}

sub finddirs {
  # Find directories, but not deeply.
  my $self = shift;
  my $dir = shift;
  $self->debug("finddirs($dir)\n");
  my @result = File::Find::Rule->directory()
                  ->mindepth(1)
                  ->maxdepth(1)
                  ->not_name('.*')
                  ->in($dir);
  $self->debug(scalar @result . " directories found\n");
  return @result;
}

sub findfiles {
  # Find files, but not deeply.
  my $self = shift;
  my $dir = shift;
  $self->debug("findfiles($dir)\n");
  return ($dir) if (-f $dir);
  my @result = File::Find::Rule->file()
                  ->mindepth(1)
                  ->maxdepth(1)
                  ->not_name('.*')
                  ->in($dir);
  $self->debug(scalar @result . " files found\n");
  return @result;
}

sub validate {
  # Look in a spool directory for files and run the is_complete check.  Return
  # a list of incomplete input files.  Note we also want to return some
  # indicator of "No output at all yet":
  #  . no input files, nothing to do, return (-1,())
  #  . no output at all, return (0,())
  #  . some output is partial, return (0,@list)
  #  . complete output is present, if @list is empty
  my $self = shift;
  my $spooldir = shift;

  $self->debug("validate($spooldir)\n");

  # Validate that all output files are present and complete.
  my @errors;
  my @infiles;

  # Validate files on the filesystem.
  # Make a list of input files:
  @infiles = (grep(!/-output/,$self->findfiles($spooldir)));

  # If there are no files, there's nothing to do.
  if (scalar @infiles == 0) {
    $self->logger("No files in spool $spooldir, nothing to do\n");
    return (-1,());
  }

  # For each input file, examine output file for "completeness".
  foreach my $infile (@infiles) {
    next unless ($infile);
    $self->debug("$infile\n");
    push @errors, basename $infile if (! $self->{suite}->is_complete($infile));
  }

  # If we have zero output, we want a job array for the whole dir.
  if (scalar @infiles == scalar @errors) {
    $self->logger("spool has no complete files yet\n");
    return (0,());
  }

  # Report errors and incompletenesses.
  $self->debug(scalar @errors . " incomplete files\n");

  # If @errors is empty, output is complete.
  return (1,()) if (scalar @errors == 0);

  # If @errors is non-empty (yet also != @infiles) then we're partially complete.
  return (0,@errors);
}

sub waitforjobs {
  my $self = shift;
  # Wait for an LSF job to complete.
  my $sleepval = $self->{config}->{sleepval};
  my $jobname = shift;
  $self->logger("waiting for jobs: $jobname\n");
  while (1) {
    my $count = $self->check_running($jobname);
    last if (! $count);
    sleep $sleepval;
  }
}

sub check_churn {
  # Check churn rate, and sleep if we're churning.
  # Churn is when we're examinining the same job too quickly.
  my $self = shift;
  my $dir = shift;
  $self->debug("check_churn($dir)\n");
  my @result = $self->{cache}->fetch($dir,'time');
  my $lastcheck = $result[0];
  return 0 if (! defined $lastcheck);
  $self->debug("last check $lastcheck\n");
  my $check = time() - $lastcheck;
  if ( $check < $self->{config}->{churnrate} ) {
    $self->debug("$check < $self->{config}->{churnrate} = churning\n");
    return 1;
  }
  return 0;
}

sub run_bqueues {
  # Use bqueues to determine queue fullness.
  my $self = shift;
  my $command = "$self->{bqueues} $self->{config}->{queue}";
  my $line = "?";

  $self->debug("run_bqueues($command)\n");

  open(COMMAND,"$command 2>&1 |") or throw Error::Simple("failed to run bqueues: $!");
  while (<COMMAND>) {
    $line = $_ if (/^$self->{config}->{queue}/);
  }
  close(COMMAND);
  my $rc = $? >> 8;

  # If bqueues can't be run for some reason, return uncertain.
  # Do this line check because we have anecdotes of bqueues running
  # and exiting 0 but not returning the output here.
  if ($line eq "?") {
    $self->debug("bqueues error: $line\n");
    return -1;
  }

  my @toks = split(/\s+/,$line);
  my $njobs = $toks[7];
  return $njobs;
}

sub run_bjobs {
  my $self = shift;
  my $command = "$self->{bjobs} -u $self->{config}->{user} -q $self->{config}->{queue}";
  my $njobs = 0;

  $self->debug("run_bjobs($command)\n");
  open(COMMAND,"$command 2>&1 |") or throw Error::Simple("failed to run bqueues: $!");
  while (<COMMAND>) {
    # skip the header
    next if (/^JOBID/);
    $njobs++;
  }
  close(COMMAND);
  my $rc = $? >> 8;

  if ($rc) {
    return -1;
  }

  return $njobs;
}

sub check_queue {
  # Check how many jobs are running.
  # Return values are:
  # 1   Queue above queueceiling
  # 0   Queue below queuefloor
  # -1  Queue between floor and ceiling
  my $self = shift;
  my $njobs;

  if ( exists $self->{config}->{user} ) {
    $njobs = $self->run_bjobs();
  } else {
    $njobs = $self->run_bqueues();
  }

  $self->debug("queue: $self->{config}->{queue} $njobs\n");
  return 1 if ( defined $njobs and $njobs > $self->{config}->{queueceiling} );
  return 0 if ( defined $njobs and $njobs < $self->{config}->{queuefloor} );
  return -1; # was full, not yet empty enough
}

sub process_dir {
  # Conditionally bsub a directory.
  my $self = shift;
  my $dir = shift;

  $self->debug("process_dir($dir)\n");

  # Ignore completed spools.
  # Check completeness from cache...
  my @result = $self->{cache}->fetch($dir,'complete');
  my $complete = $result[0];
  my @files;
  return 0 if (defined $complete and $complete == 1);

  # --- Check running before checking completeness to avoid exiting
  # complete with jobs running.
  # --- Check churn before check running...
  # If check_churn is after validation, then we end up validating
  # immediately after bsub, which is awkward...
  #
  # Note we might "churn" here, if the queue is below
  # the ceiling, but has jobs running for incomplete spools.
  # This would happen if we kill this process, but leave jobs
  # running then restart.
  my $churning = $self->check_churn($dir);
  if ($churning) {
    $self->logger("sleeping $self->{config}->{sleepval} until next check\n");
    sleep $self->{config}->{sleepval};
    # Return so as to recheck completeness (at the top of this subroutine).
    return 0;
  }

  # Update the time of this check, do so after churn check and before check_running.
  $self->{cache}->add($dir,'time',time());

  # Check running before queue full and bsub, after check_churn...
  # Ignore currently running spools.
  if ($self->check_running($dir) > 0) {
    $self->logger("skipping active spool " . basename $dir . "\n");
    return 0;
  }
  # --- Keep check_running near check_churn

  # Check filesystem completeness before bsubbing, after check_running...
  ($complete,@files) = $self->validate($dir);

  if ($complete == -1) {
    # -1 is set by validate() when there are no files in spool
    return 0;
  } elsif ($complete) {
    # Filesystem says this $dir is complete, mark it so.
    $self->logger("$dir complete\n");
    $self->{cache}->add($dir,'complete',1);
    return 0;
  } else {
    $self->logger("$dir incomplete\n");
    $self->{cache}->add($dir,'complete',0);
    $self->debug("incomplete files: " . join(",",@files) . "\n");
    $self->{cache}->add($dir,'files',join(",",@files));
  }

  # Conditionally return right after completeness check
  # if we only want the cache built.
  return 0 if ($self->{buildonly});

  # check_running was here... but led to marking complete before jobs finished.

  # Check queue full before retry limit and bsub...
  # When queue is full, sleep until we hit queuefloor.
  my $full = $self->check_queue();
  if ($full == 1) {
    while ($full != 0) {
      $self->logger("sleeping $self->{config}->{sleepval} until queue empties\n");
      sleep $self->{config}->{sleepval};
      $full = $self->check_queue();
    }
    # Return so as to recheck completeness (at the top of this subroutine).
    return 0;
  }

  # Check retry limit before bsub...
  # If we set a retry limit, respect it.
  @result = $self->{cache}->fetch($dir,'count');
  my $count = $result[0];
  if ($self->{config}->{lsf_tries} > 0 and
      defined $count and
      $count >= $self->{config}->{lsf_tries}) {
    $self->{cache}->add($dir,'complete',-1);
    $self->logger("over the retry limit $self->{config}->{lsf_tries} for " . basename $dir . ", giving up\n");
    return 0;
  }

  # Check a stop flag that would halt submission...
  if ( exists $self->{config}->{stopflag} and -f $self->{config}->{stopflag} ) {
    $self->{cache}->add($dir,'time',time());
    $self->logger("Stop flag is set, skipping bsub\n");
    return 0;
  }

  # Bsub...
  my $jobid;
  if (scalar @files) {
    # Resubmit just the failures from the last run.
    foreach my $incomplete (@files) {
      $jobid = $self->bsub("$dir/$incomplete");
    }
  } else {
    # If specific files weren't present, do the whole dir.
    $jobid = $self->bsub($dir);
  }
  $self->{cache}->add($dir,'time',time());
  $self->{cache}->counter($dir);

  return 0;
}

sub process_cache {
  # Traverse the cache, submitting items as we go.

  my $self = shift;

  $self->debug("process_cache()\n");

  while (1) {

    # Sorted list of incomplete spool dirs.
    my @dirlist = sort { ($a =~ /^.*-(\d+)$/)[0] <=> ($b =~ /^.*-(\d+)/)[0] } $self->{cache}->fetch_complete(0);

    # We're done when there's nothing left to do.
    return 0 if (scalar @dirlist == 0);

    my $startflag = 0;

    foreach my $dir ( @dirlist ) {

      # If we set starting position, check it.
      my $base;
      $base = basename $dir;

      $self->debug("check cached dir $dir\n");
      $self->process_dir($dir);
      $self->debug("done with dir $dir\n");
    }
  }
}

sub build_cache {
  # Traverse spoolname and build a cache representing how much
  # work has been done.

  my $self = shift;
  my $spoolname = shift;

  $self->debug("build_cache($spoolname)\n");

  if (! defined $self->{cachefile}) {
    $self->{cachefile} = $spoolname . ".cache";
  }

  # Make a log dir as a sibling to the cache file.
  $self->{logdir} = $spoolname . ".logs";
  if (! -d $self->{logdir}) {
    mkdir $self->{logdir} or
      throw Error::Simple("cannot create log directory $self->{logdir}: $!");
  }

  $self->{cache}->prep();

  # If this is a spool dir of dirs, process the dirs.
  my @dirlist = $self->finddirs($spoolname);
  @dirlist = sort { ($a =~ /^.*-(\d+)$/)[0] <=> ($b =~ /^.*-(\d+)/)[0] } @dirlist;

  # If this is a spool dir of files, process self.
  push @dirlist,$spoolname if (scalar @dirlist == 0);

  # Sentinels used to watch for startpos and endpos, if defined.
  my $startflag = 0;

  # For each dir in the spool prep a cache entry.
  for (my $idx = 0; $idx <= $#dirlist; $idx++) {

    my $dir = $dirlist[$idx];
    next if (!$dir);

    # If the cache has this dir, move on.
    next if ($self->{cache}->fetch($dir,'spoolname'));

    # If we set starting position, check it.
    my $base;
    if (defined $self->{startpos} and !$startflag) {
       $base = basename $dir;
       $startflag = 1 if ($base eq $self->{startpos});
       next if ($startflag != 1);
    }

    $self->process_dir($dir);
    last if (defined $self->{endpos} and $base eq $self->{endpos});
  }
  $self->debug("build($spoolname) complete\n");
  return 0;
}

sub is_valid {
  # This subroutine handles the CLI invocation of validate().

  my $self = shift;
  my $spoolname = shift;
  my $retval;
  $self->debug("is_valid($spoolname)\n");

  # If this is a spool dir of dirs, process the dirs.
  my @dirlist = $self->finddirs($spoolname);
  @dirlist = sort { ($a =~ /^.*-(\d+)$/)[0] <=> ($b =~ /^.*-(\d+)/)[0] } @dirlist;

  # If this is a spool dir of files, process self.
  push @dirlist,$spoolname if (scalar @dirlist == 0);

  foreach my $spooldir (@dirlist) {

    my ($complete,@files) = $self->validate($spooldir);

    if ($complete == -1) {
      # @files is undef
      $self->logger("spool $spooldir has no files\n");
      $retval = undef;
    } elsif ($complete) {
      # retval 99 means all files validated
      $self->logger("spool $spooldir is complete\n");
      $retval = 99;
    } else {
      $self->logger("spool $spooldir is incomplete\n");
      foreach my $file (@files) {
        $self->debug("\t$file\n");
      }
      $retval = 0;
    }

    next if (!defined $retval);

    # Update cache if specifically given on CLI.
    if (defined $self->{cachefile}) {
      $self->{cache}->add($spooldir,'files',join(",",@files));
      if ($retval == 99) {
        $self->{cache}->add($spooldir,'complete',1);
      } else {
        $self->{cache}->add($spooldir,'complete',0);
      }
    }
  }
  return $retval;
}

sub version {
  my $self = shift;
  print "lsf_spool $VERSION\n";
}

sub usage {
  my $self = shift;
  print "
  lsf_spool [-hbcprsvVw] [-i cachefile] [-S subdir] [-E subdir] [-C configfile] [-l logfile] <batch_file|spool_directory>

Usage:

  -C    specify Config file name (eg: ./lsf_spool.cfg)
  -b    build a cache of spools (bsub along the way unless dryrun mode)
  -c    check the status of current query (file or dir)
  -d    enable debugging
  -E    for a spool dir, end processing at this subdir
  -h    this helpful message
  -i    for a spool dir, use this named cache file
  -l    specify log file (STDOUT by default)
  -n    dry run mode, do all except submission.
  -p    process all queries given (file or dir)
  -s    submit the given query (file or dir)
  -S    for a spool dir, start processing at this subdir
  -r    re-submit the given query (file or dir) (MAX_USER_PRIO)
  -v    validate the given query (file or dir)
  -V    display version information
  -w    wait for the given query to finish

";
 return 1;
}

sub check_args {
  # Sanity check command line arguments.
  my $self = shift;
  my @args = @_;

  $self->debug("check_args()\n");

  my $files = 0;
  my $dirs = 0;

  throw Error::Simple("no spool argument given")
    if ($#args == -1);

  # Arguments must be either all dirs or all files.
  foreach my $arg (@args) {
    throw Error::Simple("no such file or directory $arg") if (! -e $arg);
    $files = 1 if (-f $arg);
    $dirs = 1 if (-d $arg);
  }

  throw Error::Simple("arguments must be all files or all directories, not a mix") if ($files and $dirs);

  my @list = @args;

  # Canonicalize paths.
  @list = map { abs_path($_) } @list;

  # Sanity check spool dirs.
  if ($dirs) {
    foreach my $arg (@list) {
      $self->check_cwd($arg);
    }
  }

  # If a starting position (subdir) is given, validate it.
  if (defined $self->{startpos}) {
    throw Error::Simple("starting position only valid with a single spool dir") 
      if (scalar @list != 1);
    throw Error::Simple("starting position only valid with spool dir, not a batch file: $list[0]") 
      if (-f $list[0]);
    throw Error::Simple("starting directory not found in spool: $list[0]/$self->{startpos}") 
      if (! -d "$list[0]/$self->{startpos}");

    $self->{startpos} = Cwd::abs_path($list[0] . "/" . $self->{startpos});
    $self->{startpos} = basename $self->{startpos};
    $self->debug("Start spool $list[0] with sub-directory $self->{startpos}\n");
  }

  # If a stopping position (subdir) is given, validate it.
  if (defined $self->{endpos}) {
    throw Error::Simple("ending position only valid with a single spool dir") 
      if (scalar @list != 1);
    throw Error::Simple("ending position only valid with spool dir, not a batch file: $list[0]") 
      if (-f $list[0]);
    throw Error::Simple("ending directory not found in spool: $list[0]/$self->{endpos}") 
      if (! -d "$list[0]/$self->{endpos}");

    $self->{endpos} = Cwd::abs_path($list[0] . "/" . $self->{endpos});
    $self->{endpos} = basename $self->{endpos};
    $self->debug("End spool $list[0] with sub-directory $self->{endpos}\n");
  }

  throw Error::Simple("empty argument list") if (scalar @list == 0);
  return @list;
}

sub read_config {
  # Read a simple configuration file that contains a hash object
  # and subroutines.
  my $self = shift;

  # YAML has Load
  use YAML::XS;
  # Slurp has read_file
  use File::Slurp;

  throw Error::Simple("please specify a config file with the -C option")
    if (! defined $self->{configfile});

  my $configfile = abs_path($self->{configfile});

  try {
    $self->{config} = Load scalar read_file($configfile);
  } catch Error with {
    my $ex = shift;
    throw Error::Simple("error loading config file '$configfile': $ex->{-text}");
  }

  # Validate configuration.
  my @required = ('queue', 'sleepval', 'queueceiling',
                   'queuefloor', 'churnrate', 'lsf_tries', 'db_tries' );
  my $req;
  foreach $req (@required) {
    throw Error::Simple("configuration is missing required parameter '$req'")
      if (! exists $self->{config}->{$req});
  }
  @required = ('name', 'parameters',);
  foreach $req (@required) {
    throw Error::Simple("configuration is missing required parameter '$req'")
      if (! exists $self->{config}->{suite}->{$req});
  }
}

sub activate_suite {
  # Now activate the configured suite.
  my $self = shift;
  my $class = $self->{config}->{suite}->{name};
  $self->debug("Activating suite: $class\n");
  my $suite = LSFSpool::Suite->instantiate($class,$self);

  $self->{suite} = $suite;
  throw Error::Simple("configured suite has no method 'is_complete'")
    if ( ! $suite->can( "is_complete" ) );
}

sub prepare_logger {
  # Set the file handle for the log.
  # Use logfile in .cfg if not given on CLI.
  my $self = shift;
  # Config may have logfile
  if (defined $self->{config}->{logfile}) {
    $self->{logfile} = $self->{config}->{logfile};
  }
  # Command line overrides config file
  if (defined $self->{logfile}) {
    $self->{logfile} = $self->{logfile};
  }
  # Open logfile or STDOUT.
  if (defined $self->{logfile}) {
    open(LOGFILE,">>$self->{logfile}") or
      throw Error::Simple("failed to open log file $self->{logfile}: $!");
    $self->{logfh} = \*LOGFILE;
  } else {
    $self->{logfh} = \*STDOUT;
  }
}

sub find_progs {
  # Find ancillary software.
  my $self = shift;

  $self->debug("find_progs()\n");

  # We shell out to bsub because LSF::Jobs is insufficient.
  my $bsub = `which bsub 2>/dev/null`;
  chomp $bsub;
  throw Error::Simple("cannot find bsub in PATH")
    if (length "$bsub" == 0);
  $self->{bsub} = $bsub;

  # We shell out to bqueues.
  my $bqueues = `which bqueues 2>/dev/null`;
  chomp $bqueues;
  throw Error::Simple("cannot find bqueues in PATH")
    if (length "$bqueues" == 0);
  $self->{bqueues} = $bqueues;

  # We may shell out to bjobs.
  my $bjobs = `which bjobs 2>/dev/null`;
  chomp $bjobs;
  throw Error::Simple("cannot find bjobs in PATH")
    if (length "$bjobs" == 0);
  $self->{bjobs} = $bjobs;


  return 0;
}

sub main {

  my $self = shift;
  @ARGV = @_;
  my %opts;

  # Set auto flush, useful with "tee".
  $| = 1;

  getopts("C:bcdE:hi:l:nprsS:vVw",\%opts) or
    throw Error::Simple("Error parsing options");

  if ($opts{'h'}) {
    $self->usage();
    return 0;
  }
  if ($opts{'V'}) {
    $self->version();
    return 0;
  }

  $self->{debug} = (delete $opts{'d'}) ? 1 : 0;
  $self->{dryrun} = (delete $opts{'n'}) ? 1 : 0;
  $self->{cachefile} = (delete $opts{'i'});
  delete $opts{'i'};
  $self->{logfile} = ($opts{'l'});
  delete $opts{'l'};
  $self->{startpos} = ($opts{'S'});
  delete $opts{'S'};
  $self->{endpos} = ($opts{'E'});
  delete $opts{'E'};
  $self->{configfile} = $opts{'C'} if ($opts{'C'});
  delete $opts{'C'};

  # Read configuration file, may have logfile setting in it.
  $self->read_config();

  # Open log file as soon as we have options parsed.
  $self->prepare_logger();

  if (scalar keys(%opts) > 1) {
    $self->logger("select only one action: " . join(" ", keys %opts) . "\n\n");
    $self->usage();
    return 1;
  }

  # Activate the specified Suite, which defines what actions we're
  # going to submit to LSF and how we identify them as "complete".
  $self->activate_suite();

  # Find required programs.
  $self->find_progs();

  # Ensure args are proper.
  my @joblist = $self->check_args(@ARGV);

  my $rc = 0;
  foreach my $job (@joblist) {

    if ($opts{'b'}) {
      $self->{buildonly} = 1;
      $rc = $self->build_cache($job);
      $self->logger("added $job to cache\n");
    } elsif ($opts{'c'}) {
      $rc = $self->check_running($job);
    } elsif ($opts{'r'}) {
      $rc = $self->bsub($job,0,1);
    } elsif ($opts{'s'}) {
      $rc = $self->bsub($job);
    } elsif ($opts{'w'}) {
      $rc = $self->waitforjobs($job);
    } elsif ($opts{'p'}) {

      if (! -d $job) {
        throw Error::Simple("consider -s option with files, not -p");
      }

      $self->logger("begin processing $job\n");
      $rc = $self->build_cache($job);
      $rc = $self->process_cache();

      # did we give up on any sub dirs?
      my @dirlist = sort { ($a =~ /^.*-(\d+)$/)[0] <=> ($b =~ /^.*-(\d+)/)[0] } $self->{cache}->fetch_complete(-1);

      if (scalar @dirlist > 0) {
        $self->logger("there were errors processing $job\n");
        foreach my $dir (@dirlist) {
          $self->logger("$dir\n");
        }
      } else {
        $self->logger("processing complete $job\n");
      }

    } elsif ($opts{'v'}) {
      # Connect to cache if given on CLI.
      if (defined $self->{cachefile}) {
        $self->{cache}->prep($self->{cachefile});
      }
      $rc = $self->is_valid($job);
    } else {
      if (scalar keys %opts) {
        $self->usage();
        throw Error::Simple("unknown option: " . join(" ", keys %opts));
      } else {
        $self->usage();
        throw Error::Simple("no action specified\n\n");
      }
    }
  }
  close($self->{logfh})
    if ($self->{logfh} != \*STDOUT);

  $self->{dbh}->disconnect() if (defined $self->{dbh});

  # Note this only returns the *last* return code...
  # This isn't very robust, but is better than nothing for now.
  return $rc;
}

1;
__END__

=pod

=head1 NAME

LSFSpool - Manage a lsf job spool

=head1 SYNOPSIS

  lsf_spool [-hbcprsvVw] [-i cachefile] [-S subdir] [-E subdir] [-C configfile] [-l logfile] <batch_file|spool_directory>

=head1 OPTIONS

  -C    specify Config file name (eg: ./lsf_spool.cfg)
  -b    build a cache of spools (don't bsub along the way)
  -d    enable debugging
  -c    check the status of current query (file or dir)
  -E    for a spool dir, end processing at this subdir
  -h    this helpful message
  -i    for a spool dir, use this named cache file
  -l    specify log file (STDOUT by default)
  -n    dry run mode, do all except submission.
  -p    process all queries given (file or dir)
  -s    bsub the given query (file or dir)
  -S    for a spool dir, start processing at this subdir
  -r    re-bsub the given query (file or dir) (MAX_USER_PRIO)
  -v    validate the given query (file or dir)
  -V    display version information
  -w    wait for the given query to finish

=head1 DESCRIPTION

This module is for managing a spool of files to be processed via LSF.

Given a set of input files A, a program B, and a "completeness condition",
this program will attempt to submit jobs to LSF in such a way as to 
satisfy the following conditions:

  - Keep trying to run B on A until "complete".
  - Keep the LSF queue "full" but not "too full".
  - Don't resubmit jobs that keep failing, ie. "churn".

=head1 CONFIGURATION

The file B<lsf_spool.cfg>, residing normally in B<~/.lsf_spool>, contains
a variety of configuration parameters.

The configuration file is YAML formatted file containing the table of options.

  suite:
    name: BLAST
    parameters: -db /opt/nr/nr-20100424_0235/nr -matrix BLOSUM62 -evalue 100 -word_size 6 -threshold 23 -num_descriptions 10 -num_alignments 10 -lcase_masking -seg yes -soft_masking true -window_size 0
  queue: backfill
  sleepval: 60
  queueceiling: 10000
  queuefloor: 1000
  churnrate: 30
  lsf_tries: 2
  db_tries: 1
  email: user@genome.wustl.edu
  user:  user

  - suite
    + name       : The certified program to run (eg. BLAST)
    + parameters : Parameters for the program
  - queue        : The LSF queue to submit to.
  - user         : The LSF user, only count this user's jobs.
  - sleepval     : Seconds to sleep between status checks.
  - churnrate    : Seconds before which a job should not be resubmitted.
  - queueceiling : Number of jobs representing a "full" queue.
  - queuefloor   : Number of jobs representing an "empty" queue.
  - email         : Email address for LSF to email notifications to (NOISY!).
  - lsf_tries    : Number of repeat attempts at a job, 0 means infinite.
  - db_tries     : Number of times to retry DB connection.

Be careful with the B<email> option.  B<Millions of jobs make millions of emails.>

=head1 EXAMPLES

Add the B<-d> option to enable debugging for any other option.
Add the B<-l> option to log to a named log file.

For example, given a FASTA file s_1_1_for_bwa_input.pair_a with millions
of DNA sequences, break this up into a spool of batch files with some set
parameters, usually chosen to satisfy LSF job parameters.

  # mkdir spool
  # cd !$
  # mv s_1_1_for_bwa_input.pair_a .
  # mkdir seq-s_1_1_for_bwa_input.pair_a
  # cd seq-s_1_1_for_bwa_input.pair_a
  # batch_fasta --reads 500 --batches 100 ../s_1_1_for_bwa_input.pair_a

The above produces a directory structure like:

  ./spool/seq-s_1_1_for_bwa_input.pair_a
  ./spool/seq-s_1_1_for_bwa_input.pair_a/seq-s_1_1_for_bwa_input.pair_a-1
  ./spool/seq-s_1_1_for_bwa_input.pair_a/seq-s_1_1_for_bwa_input.pair_a-2
  ./spool/seq-s_1_1_for_bwa_input.pair_a/seq-s_1_1_for_bwa_input.pair_a-3
  ./spool/seq-s_1_1_for_bwa_input.pair_a/seq-s_1_1_for_bwa_input.pair_a-4
  ...
  ./spool/seq-s_1_1_for_bwa_input.pair_a/seq-s_1_1_for_bwa_input.pair_a-N

Now this directory is the "spooldir":

  ./spool/seq-s_1_1_for_bwa_input.pair_a

Process the entire spool via:

  # lsf_spool -l ./spool/seq-s_1_1_for_bwa_input.pair_a.log \
    -p ./spool/seq-s_1_1_for_bwa_input.pair_a

Some other examples:

  # lsf_spool -d -s spooldir

Submit each file in B<spooldir> to LSF by running B<program> with B<parameters>.

  # lsf_spool -d -r spooldir

Retry the spooldir.  This is the same as B<-s> but with a higher LSF priority
(300).

  # lsf_spool -d -r spooldir/batchfile

Resubmit just one batchfile within the spooldir.

  # lsf_spool -d -p spooldir

Process the spooldir, submitting each job within it including subdirectories (1
level of depth), until they are all complete.  This will try B<lsf_tries> times
to run B<program> on B<inputfile> from spooldir, and will keep running until
the spooldir has been completely processed.

  # lsf_spool -d -p spooldir/batchfile

Process a single batchfile in the spooldir, retrying it until it is done.

  # lsf_spool -d -w spooldir

Wait for any running jobs on spooldir.

  # lsf_spool -d -c spooldir

Check spooldir for any running jobs.

  # lsf_spool -d -v spooldir

Validate each file in spooldir with the is_complete() check.  This will display
any incomplete files.

=head1 CLASS METHODS

=over

=item new()

Instantiates the class.

=item debug($)

Logs a line if debug is true.

=item logger($)

Logs a line.

=item parsefile($)

Parses a batch file name and returns the proper spool directory, input file
name, and job array string.

=item parsedir($)

Parses a spool directory name and returns the proper spool directory, input file
name, and job array string.

=item bsub($;$$)

Calls bsub to run a command.

=item check_cwd($)

Examines the contents of a spool directory and performs sanity checks.  A spool
directory should contain all files or all directories, and each of these should
have a name that fits the regex /^\w+-\d+-\d+/, as produced by the
batch_fasta.pl program, for example.

=item check_running($)

Determine if LSF jobs are currently running for the spool directory.

=item finddirs($)

Find (not deeply) directories in a path.

=item findfiles($)

Find (not deeply) files in a path.

=item validate($)

Validate outptu files in a spool directory by calling a Suite's "is_complete"
method on each one.

=item waitforjobs($)

Check for running LSF jobs and wait for them to complete.

=item check_churn($)

Check the last check time for a spool directory and indicate if it was checked
"too soon" for another check.

=item check_queue($)

Check the LSF queue for the named spool and determine if it is "full"
or empty enough for more work.

  1   Queue above queueceiling
  0   Queue below queuefloor
 -1   Queue between floor and ceiling

=item process_dir($)

Process the spool directory, submitting jobs for incomplete input files.

=item process_cache()

Process cached spool directories, submitting jobs for incomplete input files.

=item build_cache()

Build a cache of completed work for a given spool directory.  This is an SQLite
file in the home directory (.lsf_spool).

=item is_valid($)

Check a file for completeness.

=item usage()

Print the program's usage summary.

=item check_args()

Sanity check command line arguments.

=item read_config()

Read the YAML formatted configuration file.

=item activate_suite($)

Activate the named Suite, makeing "action" and "is_complete" available for the
named command.

=item prepare_logger()

Prepare a log file or STDOUT for use with logger() and debug().

=item find_progs()

Find LSF external programs.

=item main()

The main program body.

=back

=head1 AUTHOR

Matthew Callaway

=head1 COPYRIGHT

Copyright 2010 Matthew Callaway

This program is free software; you can redistribute it and/or modify it
under the same terms as Perl itself.

=head1 KNOWN ISSUES

- lsf_spool.cfg has "db", which assumes blastx, generalize parameters.  eg. -query -db -out
- Call out to things like basename less frequently.
- Move is_complete and blast specifics to an extensible library.
