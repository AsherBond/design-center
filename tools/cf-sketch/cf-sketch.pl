#!/usr/bin/perl

package CFSketch;

use FindBin;
use lib "$FindBin::Bin/../lib", "$FindBin::Bin/perl-lib";

use warnings;
use strict;
use File::Compare;
use File::Copy;
use File::Find;
use File::Spec;
use File::Temp qw/ tempfile tempdir /;
use Cwd;
use File::Path qw(make_path remove_tree);
use File::Basename;
use Data::Dumper;
use Term::ANSIColor qw(:constants);
use Parser;
use Util;
use DesignCenter::Config;

$Term::ANSIColor::AUTORESET = 1;

my $VERSION="2.0";
my $DATE="September 2012";

my $coder;
my $canonical_coder;

BEGIN
{
    eval
    {
     require JSON::XS;
     $coder = JSON::XS->new()->relaxed()->utf8()->allow_nonref();
     # for storing JSON data so it's directly comparable
     $canonical_coder = JSON::XS->new()->canonical()->utf8()->allow_nonref();
    };
    if ($@ )
    {
     Util::color_warn "Falling back to plain JSON module (you should install JSON::XS)";
     require JSON;
     $coder = JSON->new()->relaxed()->utf8()->allow_nonref();
     # for storing JSON data so it's directly comparable
     $canonical_coder = JSON->new()->canonical()->utf8()->allow_nonref();
    }
}

######################################################################
###### Some basic constants and settings.

use constant SKETCH_DEF_FILE => 'sketch.json';

$| = 1;                         # autoflush

######################################################################

my $config = new DesignCenter::Config;
$config->load;

# Version and date information
$config->version($VERSION);
$config->date($DATE);

# Load commands and do other parser initialization
Parser::init('cf-sketch', $config, @ARGV);

# Run the main command loop
Parser::parse_commands();

# Finishing code.
Parser::finish();

exit(0);

######################################################################

my $required_version = '3.4.0';
my $version = cfengine_version();

if (!$config->force && $required_version gt $version)
{
 Util::color_die "Couldn't ensure CFEngine version [$version] is above required [$required_version], sorry!";
}

# Allow both comma-separated values and multiple occurrences of --repolist
$config->repolist([ split(/,/, join(',', @{$config->repolist})) ]);

my @list;
foreach my $repo (@{$config->repolist})
{
 if (is_resource_local($repo))
 {
  my $abs = File::Spec->rel2abs($repo);
  if ($abs ne $repo)
  {
   print "Remapped $repo to $abs so it's not relative\n"
    if $config->verbose;
   $repo = $abs;
  }
 }
 else                                   # a remote repository
 {
 }

 push @list, $repo;
}

$config->repolist(\@list);

my $quiet       = $config->quiet;
my $dryrun      = $config->dryrun;
my $veryverbose = $config->veryverbose;
my $verbose     = $config->verbose || $veryverbose;

#print "Full configuration: ", $coder->encode(\%options), "\n" if $verbose;

# TODO - fix this
# my $save_metarun = $config->savemetarun;
# if ($save_metarun)
# {
#  maybe_ensure_dir(dirname($save_metarun));
#  maybe_write_file($save_metarun,
#                   'metarun file',
#                   $coder->pretty(1)->encode({ options => \%options }));
#  print GREEN "Saved metarun file $save_metarun\n";
#  exit;
# }

if ($config->saveconfig)
{
 configure_self($config->configfile);
 exit;
}

if ($config->list)
{
 # 'all' matches everything
 list(($config->list->[0] eq 'all' || $config->list->[0] eq '') ?
      ["."] : $config->list);
 exit;
}

if ($config->search)
{
 search($config->search->[0] eq 'all' ? ["."] : $config->search);
 exit;
}

if (scalar @{$config->makepackage})
{
 make_packages($config->makepackage);
 exit;
}

if ($config->listactivations)
{
 my $activations = load_json($config->actfile, 1);
 Util::color_die "Can't load any activations from $config->actfile"
  unless defined $activations && ref $activations eq 'HASH';

 my $activation_id = 1;
 foreach my $sketch (sort keys %$activations)
 {
  if ('HASH' eq ref $activations->{$sketch})
  {
   Util::color_warn "Skipping unusable activations for sketch $sketch!";
   next;
  }

  foreach my $activation (@{$activations->{$sketch}})
  {
   print BOLD GREEN."$activation_id\t".YELLOW."$sketch".RESET,
    $coder->encode($activation),
     "\n";

   $activation_id++;
  }
 }
 exit;
}

if ($config->deactivateall)
{
 $config->deactivate('.*');
}

my @nonterminal = qw/deactivate remove install activate generate/;
my @terminal = qw/test api search/;
my @callable = (@nonterminal, @terminal);

foreach my $word (@callable)
{
 if ($config->$word)
 {
  # TODO: hack to replace a method table, eliminate
  no strict 'refs';
  $word->($config->$word);
  use strict 'refs';

  # exit unless the command was non-terminal...
  exit unless grep { $_ eq $word } @nonterminal;
 }
}

# now exit if any non-terminal commands were specified
exit if grep { $config->$_ } @nonterminal;

push @callable, 'list', 'save-config';
Util::color_die "Sorry, I don't know what you want to do.  You have to specify a valid verb. Run $0 --help to see the complete list.\n";

sub configure_self
{
 my $cf    = shift @_;

 my %keys = (
             'repolist' => 1,             # array
             'cfpath'   => 0,             # string
             installsource => 0,
             installtarget => 0,
             actfile => 0,
             'runfile' => 0,
            );

 print "Saving configuration keys [@{[sort keys %keys]}] to file $cf\n" unless $quiet;

 my %config;

 foreach my $key (sort keys %keys) {
   $config{$key} = $config->$key;
   print "Saving option $key=".tersedump($config{$key})."\n"
     if $verbose;
 }

 maybe_ensure_dir(dirname($cf));
 maybe_write_file($cf, 'configuration input', $coder->pretty(1)->encode(\%config));
}

sub list
{
 my $terms = shift @_;

 foreach my $repo (@{$config->repolist})
 {
  my @sketches = list_internal($repo, $terms);

  my $contents = repo_get_contents($repo);

  foreach my $sketch (@sketches)
  {
   # this format is easy to parse, even if the directory has spaces,
   # because the first two fields won't have spaces
   my @docs = grep {
    $contents->{$sketch}->{manifest}->{$_}->{documentation}
   } sort keys %{$contents->{$sketch}->{manifest}};

   print GREEN, "$sketch", RESET, " $contents->{$sketch}->{fulldir}\n";
  }
 }
}

sub list_internal
{
 my $repo  = shift @_;
 my $terms = shift @_;

 my @ret;

 print "Looking for terms [@$terms] in cf-sketch repository [$repo]\n"
  if $verbose;

 my $contents = repo_get_contents($repo);
 print "Inspecting repo contents: ", $coder->encode($contents), "\n"
  if $verbose;

 foreach my $sketch (sort keys %$contents)
 {
  # TODO: improve this search
  my $as_str = $sketch . ' ' . $coder->encode($contents->{$sketch});

  foreach my $term (@$terms)
  {
   next unless $as_str =~ m/$term/;
   push @ret, $sketch;
   last;
  }
 }

 return @ret;
}

# Produce the appropriate input directory depending on --fullpath
sub inputfile {
  my @paths=@_;
  if ($config->fullpath) {
      return File::Spec->catfile(@paths);
  }
  else {
      return File::Spec->catfile('sketches', @paths);
  }
}

# generate the actual cfengine config that will run all the cf-sketch bundles
sub generate
{
   # activation successful, now install it
   my $activations = load_json($config->actfile, 1);
   Util::color_die "Can't load any activations from $config->actfile"
    unless defined $activations && ref $activations eq 'HASH';

   my $activation_counter = 1;
   my $template_activations = {};
   my $standalone = $config->standalone;
   my $run_file = $config->runfile;

   my @inputs;
   my %dependencies;

 ACTIVATION:
   foreach my $sketch (sort keys %$activations)
   {
    my $prefix = $sketch;
    $prefix =~ s/::/__/g;

    foreach my $repo (@{$config->repolist})
    {
     my $contents = repo_get_contents($repo);
     if (exists $contents->{$sketch})
     {
      if ('HASH' eq ref $activations->{$sketch})
      {
       Util::color_warn "Skipping unusable activations for sketch $sketch!\n";
       next;
      }

      my $activation_id = 1;
      foreach my $pdata (@{$activations->{$sketch}})
      {
       print "Loading activation $activation_id for sketch $sketch\n"
        if $verbose;
       Util::color_die "Couldn't load activation params for $sketch: $!"
        unless defined $pdata;

       my $data = $contents->{$sketch};

       my %types;
       my %booleans;
       my %vars;

       my $entry_point = verify_entry_point($sketch, $data);

       Util::color_die "Could not load the entry point definition of $sketch"
        unless $entry_point;

       # for null entry_point and interface definitions, don't write
       # anything in the runme template
       unless (exists $entry_point->{bundle_name})
       {
        my $input = make_include($data->{fulldir}, dirname($run_file) , @{$data->{interface}});
        push @inputs, $input;
        print "Entry point: added input $input for runfile $run_file\n"
         if $verbose;
        next;
       }

       $dependencies{$_} = 1 foreach collect_dependencies($data->{metadata}->{depends});
       my $activation = {
                         file => File::Spec->catfile($data->{dir}, $data->{entry_point}),
                         dir => $data->{dir},
                         fulldir => $data->{fulldir},
                         entry_bundle => $entry_point->{bundle_name},
                         entry_bundle_namespace => $entry_point->{bundle_namespace},
                         activation_id => $activation_id,
                         dependencies => [ sort keys %dependencies ],
                         pdata  => $pdata,
                         sketch => $sketch,
                         prefix => $prefix,
                        };

       my $varlist = $entry_point->{varlist};

       # provide the metadata that could be useful
       my @files = sort keys %{$data->{manifest}};

       push @$varlist,
       {
        name => 'sketch_depends',
        type => 'slist',
        value => [ sort keys %dependencies ],
       },
       {
        name => 'sketch_authors',
        type => 'slist',
        value => [ sort @{$data->{metadata}->{authors}} ],
       },
       {
        name => 'sketch_portfolio',
        type => 'slist',
        value => [ sort @{$data->{metadata}->{portfolio}} ],
       },
       {
        name => 'sketch_manifest',
        type => 'slist',
        value => \@files,
       };

       my @manifests = (
                        {
                         name => 'sketch_manifest_cf',
                         type => 'slist',
                         value => [ sort grep { $_ =~ m/\.cf$/ } @files ],
                        },
                        {
                         name => 'sketch_manifest_docs',
                         type => 'slist',
                         value => [ sort grep { $data->{manifest}->{$_}->{documentation} } @files ],
                        }
                       );

       push @$varlist, @manifests;

       my %leftovers = map { $_ => 1 } @files;
       foreach my $m (@manifests)
       {
        foreach (@{$m->{value}})
        {
         delete $leftovers{$_};
        }
       }

       if (scalar keys %leftovers)
       {
        push @$varlist,
        {
         name => 'sketch_manifest_extra',
         type => 'slist',
         value => [ sort keys %leftovers ],
        };
       }

       foreach my $key (qw/version name license/)
       {
        push @$varlist,
        {
         name => "sketch_$key",
         type => 'string',
         value => '' . $data->{metadata}->{$key},
        };
       }

       $activation->{vars} = $varlist;

       my $ak = sprintf('%03d', $activation_counter++);
       $template_activations->{$ak} = $activation; # the activation counter is 1..N globally!
       $activation_id++;        # the activation ID is 1..N per sketch
      }

      next ACTIVATION;
     }
    }
    Util::color_die "Could not find sketch $sketch in repo list @{$config->repolist}";
   }

   # this removes found keys in %dependencies!
   my @dep_inputs = collect_dependencies_inputs(dirname($run_file), \%dependencies);
   if ($verbose)
   {
    print "Dependency: added input $_ for runfile $run_file\n"
     foreach @dep_inputs;
   }

   push @inputs, @dep_inputs;

   my @deps = keys %dependencies;
   if (scalar @deps)
   {
    Util::color_die "Sorry, can't generate: unsatisfied dependencies [@deps]";
   }

   # process input template, substituting variables
   foreach my $a (sort keys %$template_activations)
   {
    my $act = $template_activations->{$a};
    my $input = make_include($act->{fulldir}, dirname($run_file) , basename($act->{file}));
    push @inputs, $input;
    print "Input template: added input $input for runfile $run_file\n"
     if $verbose;
   }

   my $includes = join ', ', map { my @p = recurse_print($_); $p[0]->{value} } Util::uniq(@inputs);

   # maybe make the run template configurable?
   my $output = make_runfile($template_activations, $includes, $standalone, $run_file);

   maybe_write_file($run_file, 'run', $output);
   print GREEN "Generated ".($standalone?"standalone":"non-standalone")." run file $run_file\n"
    unless $quiet;

}

sub api
{
 my $sketch = shift @_;

 my $found = 0;
 foreach my $repo (@{$config->repolist})
 {
  my $contents = repo_get_contents($repo);
  if (exists $contents->{$sketch})
  {
   my $data = $contents->{$sketch};
   my $if = $data->{interface};

   my $entry_point = verify_entry_point($sketch, $data);

   if ($entry_point)
   {
     $found = 1;

     local $Data::Dumper::Terse = 1;
     local $Data::Dumper::Indent = 0;
     if ($config->json)
     {
       my %api = (
                  vars => $entry_point->{varlist},
                  returns => $entry_point->{returns},
                 );
       print $coder->pretty(1)->encode(\%api)."\n";
     }
     else
     {
       print GREEN "Sketch $sketch\n";
       if ($data->{entry_point})
       {
        print BOLD BLUE."  Entry bundle name:".RESET." $entry_point->{bundle_name}\n";

        foreach my $var (@{$entry_point->{varlist}})
        {
         my @p = recurse_print($var->{default}) if exists $var->{default};

         my $desc = join ",\t", (
                                 $var->{passed} ? 'passed    ' : 'not passed',
                                 sprintf('%20s', $var->{type}),
                                 exists $var->{default} ? ("optional (default $p[0]->{value})") : "mandatory",
                              );
         printf("var ".BLUE."%15.15s:".RESET."\t$desc\n",
                $var->{name});
        }

        foreach my $return (sort keys %{$entry_point->{returns}})
        {
         printf("ret ".BLUE."%15.15s:".RESET."\t$entry_point->{returns}->{$return}\n",
                $return);
        }
       }
       else
       {
        print BOLD BLUE "  This is a library sketch - no entry point defined.\n";
       }
     }
   }
   else
   {
    Util::color_die "I cannot find API information about $sketch.\n";
   }
  }
 }

 unless ($found)
 {
   Util::color_die "I could not find sketch $sketch. It doesn't seem to be installed.\n";
 }
}

sub activate
{
 my $aspec = shift @_;

 foreach my $sketch (sort keys %$aspec)
 {
  my $pfile = $aspec->{$sketch};

  print "Loading activation params from $pfile\n" unless $quiet;
  my $aparams_all = load_json($pfile);

  Util::color_die "Could not load activation params from $pfile"
   unless ref $aparams_all eq 'HASH';

  Util::color_die "Could not find activation params for $sketch in $pfile"
   unless exists $aparams_all->{$sketch};

  my $aparams = $aparams_all->{$sketch};

  foreach my $extra (sort keys %{$config->params})
  {
   $aparams->{$extra} = $config->params->{$extra};
   printf("Overriding aparams %s from the command line, value %s\n",
          $extra, $config->params->{$extra})
    if $verbose;
  }

  my $installed = 0;
  foreach my $repo (@{$config->repolist})
  {
   my $contents = repo_get_contents($repo);
   if (exists $contents->{$sketch})
   {
    my $data = $contents->{$sketch};
    my $if = $data->{interface};

    my $entry_point = verify_entry_point($sketch, $data);

    if ($entry_point)
    {
     my $varlist = $entry_point->{varlist};
     my $fails;
     foreach my $var (@$varlist)
     {
      if (exists $aparams->{$var->{name}})
      {
      }
      else
      {
       if (exists $var->{default})
       {
        if ($var->{type} =~ m/^LIST\(.+\)$/s &&
            ref $var->{default} eq '' &&
            $var->{default} =~ m/^KVKEYS\((\w+)\)$/)
        {
         my $default;
         foreach my $var2 (@$varlist)
         {
          my $name2 = $var2->{name};
          if ($name2 eq $1)
          {
           if (exists $aparams->{$name2} &&
               ref $aparams->{$name2} eq 'HASH')
           {
            $default = $var->{default} = [ keys %{$aparams->{$name2}} ];
           }
           else
           {
            Util::color_die "$var->{name} default KVKEYS($1) failed because $name2 did not have a valid value";
           }
          }
         }

         Util::color_die "$var->{name} KVKEYS default $var->{default} failed because a matching variable could not be found"
          unless $default;
        }
        elsif ($var->{type} =~ m/^ARRAY\(/ &&
            ref $var->{default} eq '')
        {
         my $decoded;
         eval { $decoded = $coder->decode($var->{default}); };
         Util::color_die "Given default '$var->{default}' for ARRAY variable was invalid JSON"
          unless ref $decoded eq 'HASH';

         print "Decoding default JSON data '$var->{default}' for $var->{name}\n"
          if $veryverbose;

         $var->{default} = $decoded;
        }

        $aparams->{$var->{name}} = $var->{default};
       }
       else
       {
        Util::color_die "Can't activate $sketch: its interface requires variable '$var->{name}' and no default is available"
       }
      }

      # for contexts, translate booleans to any or !any
      if (is_json_boolean($aparams->{$var->{name}}) &&
          $var->{type} eq 'CONTEXT')
      {
       $aparams->{$var->{name}} = $aparams->{$var->{name}} ? 'any' : '!any';
      }

      if (validate($aparams->{$var->{name}}, $var->{type}))
      {
       print "Satisfied by aparams: '$var->{name}'\n" if $verbose;
      }
      else
      {
       my $ad = $coder->encode($aparams->{$var->{name}});
       Util::color_warn "Can't activate $sketch: '$var->{name}' value $ad fails $var->{type} validation";
       $fails++;
      }
     }
     Util::color_die "Validation errors" if $fails;
    }
    else
    {
     Util::color_die "Can't activate $sketch: missing entry point in $data->{entry_point}"
    }

    # activation successful, now install it
    my $activations = load_json($config->actfile, 1);

    foreach my $check (@{$activations->{$sketch}})
    {
     my $p = $canonical_coder->encode($check);
     my $q = $canonical_coder->encode($aparams);
     if ($p eq $q)
     {
      if ($config->force)
      {
       Util::color_warn "Activating duplicate parameters [$q] because of --force"
        unless $quiet;
      }
      else
      {
       Util::color_die "Can't activate: $sketch has already been activated with $q";
      }
     }
    }

    push @{$activations->{$sketch}}, $aparams;
    my $activation_id = scalar @{$activations->{$sketch}};

    maybe_ensure_dir(dirname($config->actfile));
    maybe_write_file($config->actfile, 'activation', $coder->encode($activations));
    print GREEN "Activated: $sketch $activation_id aparams $pfile\n" unless $quiet;

    $installed = 1;
    last;
   }
  }

  Util::color_die "Could not activate sketch $sketch, it was not in the given list of repositories [@{$config->repolist}]"
   unless $installed;
 }
}

sub deactivate
{
 my $nums_or_name = shift @_;

 my $activations = load_json($config->actfile, 1);
 my %modified;

 if ('' eq ref $nums_or_name)     # a string or regex
 {
  foreach my $sketch (sort keys %$activations)
  {
   next unless $sketch =~ m/$nums_or_name/;
   delete $activations->{$sketch};
   $modified{$sketch}++;
   print GREEN "Deactivated: all $sketch activations\n"
    unless $quiet;
  }
 }
 elsif ('ARRAY' eq ref $nums_or_name)
 {
  my @deactivations;

  my $offset = 1;
  foreach my $sketch (sort keys %$activations)
  {
   if ('HASH' eq ref $activations->{$sketch})
   {
    Util::color_warn "Ignoring old-style activations for sketch $sketch!";
    $activations->{$sketch} = [];
    $modified{$sketch}++;
    print GREEN "Deactivated: all $sketch activations\n"
     unless $quiet;
   }

   my @new_activations;

   foreach my $activation (@{$activations->{$sketch}})
   {
    if (grep { $_ == $offset } @$nums_or_name)
    {
     $modified{$sketch}++;
     print GREEN "Deactivated: $sketch activation $offset\n" unless $quiet;
    }
    else
    {
     push @new_activations, $activation;
    }
    $offset++;
   }

   if (exists $modified{$sketch})
   {
    $activations->{$sketch} = \@new_activations;
   }
  }
 }
 else
 {
  Util::color_die "Sorry, I can't handle parameters " . $coder->encode($nums_or_name);
 }

 if (scalar keys %modified)
 {
  maybe_ensure_dir(dirname($config->actfile));
  maybe_write_file($config->actfile, 'activation', $coder->encode($activations));
 }
}

sub remove
{
 my $toremove = shift @_;

 foreach my $repo (@{$config->repolist})
 {
  next unless is_resource_local($repo);

  my $contents = repo_get_contents($repo);

  foreach my $sketch (sort @$toremove)
  {
   my @matches = grep
   {
    # accept sketch name or directory
    ($_ eq $sketch) || ($contents->{$_}->{dir} eq $sketch) || ($contents->{$_}->{fulldir} eq $sketch)
   } keys %$contents;

   unless (scalar @matches) {
     Util::color_warn "I did not find an installed sketch that matches '$sketch' - not removing it.\n";
     next;
   }
   $sketch = shift @matches;
   my $data = $contents->{$sketch};
   if (maybe_remove_dir($data->{fulldir}))
   {
    deactivate($sketch);       # deactivate all the activations of the sketch
    print GREEN "Successfully removed $sketch from $data->{fulldir}\n" unless $quiet;
   }
   else
   {
    print RED "Could not remove $sketch from $data->{fulldir}\n" unless $quiet;
   }
  }
 }
}

sub install
{
 my $sketches = shift @_;

 my $dest_repo = $config->installtarget;
 push @{$config->repolist}, $dest_repo unless grep { $_ eq $dest_repo } @{$config->repolist};

 Util::color_die "Can't install: no install target supplied!"
  unless defined $dest_repo;

 my $source = $config->installsource;
 my $base_dir = dirname($source);
 my $local_dir = is_resource_local($source);

 print "Loading cf-sketch inventory from $source\n" if $verbose;

 my $search = search_internal($source, $sketches);

 my %known = %{$search->{known}};
 my %todo = %{$search->{todo}};

 foreach my $sketch (sort keys %todo)
 {
  print BLUE "Installing $sketch\n" unless $quiet;
  my $dir = $local_dir ? File::Spec->catdir($base_dir, $todo{$sketch}) : "$base_dir/$todo{$sketch}";

  # make sure we only work with absolute directories
  my $data = load_sketch($local_dir ? File::Spec->rel2abs($dir) : $dir);

  Util::color_die "Sorry, but sketch $sketch could not be loaded from $dir!"
   unless $data;

  my %missing = map { $_ => 1 } missing_dependencies($data->{metadata}->{depends});

  # note that this will NOT catch circular dependencies!
  foreach my $missing (keys %missing)
  {
   print "Trying to find $missing dependency\n" unless $quiet;

   if (exists $todo{$missing})
   {
    print "$missing dependency is to be installed or was installed already\n"
     unless $quiet;
    delete $missing{$missing};
   }
   elsif (exists $known{$missing})
   {
    print "Found $missing dependency, trying to install it\n" unless $quiet;
    install([$missing]);
    delete $missing{$missing};
    $todo{$missing} = $known{$missing};
   }
  }

  my @missing = sort keys %missing;
  if (scalar @missing)
  {
   if ($config->force)
   {
    Util::color_warn "Installing $sketch despite unsatisfied dependencies @missing"
     unless $quiet;
   }
   else
   {
    Util::color_die "Can't install: $sketch has unsatisfied dependencies @missing";
   }
  }

  printf("Installing %s (%s) into %s\n",
         $sketch,
         $data->{file},
         $dest_repo)
   if $verbose;

  my $install_dir = File::Spec->catdir($dest_repo,
                                       split('::', $sketch));

  my $module_install_dir = File::Spec->catfile($dest_repo, $config->modulepath);

  if (maybe_ensure_dir($install_dir))
  {
   print "Created destination directory $install_dir\n" if $verbose;
   print "Checking and installing sketch files.\n" unless $quiet;
   my $anything_changed = 0;
   foreach my $file (SKETCH_DEF_FILE, sort keys %{$data->{manifest}})
   {
    my $file_spec = $data->{manifest}->{$file};
    # build a locally valid install path, while the manifest can use / separator
    my $source = is_resource_local($data->{dir}) ? File::Spec->catfile($data->{dir}, split('/', $file)) : "$data->{dir}/$file";

    my $dest;

    if ($file_spec->{module})
    {
     if (maybe_ensure_dir($module_install_dir))
     {
      print "Created module destination directory $module_install_dir\n" if $verbose;
      $dest = File::Spec->catfile($module_install_dir, split('/', $file));
     }
     else
     {
      Util::color_warn "Could not make install directory $module_install_dir, skipping $sketch";
      next;
     }
    }
    else
    {
     $dest = File::Spec->catfile($install_dir, split('/', $file));
    }

    my $dest_dir = dirname($dest);
    Util::color_die "Could not make destination directory $dest_dir"
     unless maybe_ensure_dir($dest_dir);

    my $changed = 1;

    # TODO: maybe disable this?  It can be expensive for large files.
    if (!$config->force &&
        is_resource_local($data->{dir}) &&
        compare($source, $dest) == 0)
    {
     Util::color_warn "  Manifest member $file is already installed in $dest"
      if $verbose;
     $changed = 0;
    }

    if ($changed)
    {
     if ($dryrun)
     {
      print YELLOW "  DRYRUN: skipping installation of $source to $dest\n";
     }
     else
     {
      if (is_resource_local($data->{dir}))
      {
       copy($source, $dest) or Util::color_die "Aborting: copy $source -> $dest failed: $!";
      }
      else
      {
       my $rc = getstore($source, $dest);
       Util::color_die "Aborting: remote copy $source -> $dest failed: error code $rc"
        unless is_success($rc)
      }
     }
    }

    if (exists $file_spec->{perm})
    {
     if ($dryrun)
     {
      print YELLOW "  DRYRUN: skipping chmod $file_spec->{perm} $dest\n";
     }
     else
     {
      chmod oct($file_spec->{perm}), $dest;
     }
    }

    if (exists $file_spec->{user})
    {
     # TODO: ensure this works on platforms without getpwnam
     # TODO: maybe add group support too
     my ($login,$pass,$uid,$gid) = getpwnam($file_spec->{user})
      or Util::color_die "$file_spec->{user} not in passwd file";

     if ($dryrun)
     {
      print YELLOW "  DRYRUN: skipping chown $uid:$gid $dest\n";
     }
     else
     {
      chown $uid, $gid, $dest;
     }
    }

    print "  $source -> $dest\n" if $changed && $verbose;
    $anything_changed += $changed;
   }

   unless ($quiet) {
     if ($anything_changed) {
       print GREEN "Done installing $sketch\n";
     }
     else {
       print GREEN "Everything was up to date - nothing changed.\n";
     }
   }
  }
  else
  {
   Util::color_warn "Could not make install directory $install_dir, skipping $sketch";
  }
 }
}

# TODO: need functions for: test

sub missing_dependencies
{
 my $deps = shift @_;
 my @missing;

 my %tocheck = %$deps;

 foreach my $repo (@{$config->repolist})
 {
  my $contents = repo_get_contents($repo);
  foreach my $dep (sort keys %tocheck)
  {
   if ($dep eq 'os' &&
       ref $tocheck{$dep} eq 'ARRAY')
   {
    # TODO: get uname from cfengine?
    # pick either /bin/uname or /usr/bin/uname
    my $uname_path = -x '/bin/uname' ? '/bin/uname -o' : '/usr/bin/uname -s';
    my $uname = 'unknown';
    if (-x (split ' ', $uname_path)[0])
    {
     $uname = `$uname_path`;
     chomp $uname;
    }

    foreach my $os (sort @{$tocheck{$dep}})
    {
     if ($uname =~ m/$os/i)
     {
      print "Satisfied OS dependency: $uname matched $os\n"
       if $verbose;

      delete $tocheck{$dep};
     }
    }

    if (exists $tocheck{$dep})
    {
     print YELLOW "Unsatisfied OS dependencies: $uname did not match [@{$deps->{$dep}}]\n"
      if $verbose;
    }
   }
   elsif ($dep eq 'cfengine' &&
          ref $tocheck{$dep} eq 'HASH' &&
          exists $tocheck{$dep}->{version})
   {
    my $version = cfengine_version();
    if ($version ge $tocheck{$dep}->{version})
    {
     print "Satisfied cfengine version dependency: $version present, needed ",
      $tocheck{$dep}->{version}, "\n"
       if $veryverbose;

     delete $tocheck{$dep};
    }
    else
    {
     print YELLOW "Unsatisfied cfengine version dependency: $version present, need ",
      $tocheck{$dep}->{version}, "\n"
       if $verbose;
    }
   }
   elsif (exists $contents->{$dep})
   {
    my $dd = $contents->{$dep};
    # either the version is not specified or it has to match
    if (!exists $tocheck{$dep}->{version} ||
        $dd->{metadata}->{version} >= $tocheck{$dep}->{version})
    {
     print "Found dependency $dep in $repo\n" if $veryverbose;
     # TODO: test recursive dependencies, right now this will loop
     # TODO: maybe use a CPAN graph module
     push @missing, missing_dependencies($dd->{metadata}->{depends});
     delete $tocheck{$dep};
    }
    else
    {
     print YELLOW "Found dependency $dep in $repo but the version doesn't match\n"
      if $verbose;
    }
   }
  }
 }

 push @missing, sort keys %tocheck;
 if (scalar @missing)
 {
  print YELLOW "Unsatisfied dependencies: @missing\n" unless $quiet;
 }

 return @missing;
}

sub find_remote_sketches
{
 my $urls = shift @_;
 my $noparse = shift @_ || 0;
 my %contents;

 foreach my $repo (@$urls)
 {
  my $sketches_url = "$repo/cfsketches";
  my $sketches = lwp_get_remote($sketches_url)
   or Util::color_die "Unable to retrieve $sketches_url : $!\n";

  foreach my $sketch_dir ($sketches =~ /(.+)/mg)
  {
   my $info = load_sketch("$repo/$sketch_dir", undef, $noparse);
   next unless $info;
   $contents{$info->{metadata}->{name}} = $info;
  }
 }

 return \%contents;
}

sub find_sketches
{
 my $dirs = shift @_;
 my $noparse = shift @_ || 0;

 my %contents;

 my @dirs = grep { -r $_ && -x $_ } @$dirs;

 if (scalar @dirs)
 {
  foreach my $topdir (@dirs)
  {
   find(sub
        {
         my $f = $_;
         if ($f eq SKETCH_DEF_FILE)
         {
          my $info = load_sketch($File::Find::dir, $topdir, $noparse);
          return unless $info;
          $contents{$info->{metadata}->{name}} = $info;
         }
        }, $topdir);
  }
 }

 return \%contents;
}

sub load_sketch
{
 my $dir    = shift @_;
 my $topdir = shift @_;
 my $noparse = shift @_ || 0;

 my $name = is_resource_local($dir) ? File::Spec->catfile($dir, SKETCH_DEF_FILE) : "$dir/" . SKETCH_DEF_FILE;
 my $json = load_json($name);

 my $info = {};
 my @messages;

 # stage 1: the data must be valid and a hash
 unless (defined $json && ref $json eq 'HASH')
 {
  push @messages, "Invalid JSON data";
 }

 # stage 2: check top-level manifest and metadata keys
 unless (scalar @messages)
 {
  # the manifest must be a hash
  push @messages, "Invalid manifest" unless (exists $json->{manifest} && ref $json->{manifest} eq 'HASH');

  # the metadata must be a hash
  push @messages, "Invalid metadata" unless (exists $json->{metadata} && ref $json->{metadata} eq 'HASH');

  # the interface must be an array
  push @messages, "Invalid interface" unless (exists $json->{interface} && ref $json->{interface} eq 'ARRAY');
 }

 # stage 3: check metadata details
 unless (scalar @messages)
 {
  # need a 'depends' key that points to a hash
  push @messages, "Invalid dependencies structure" unless (exists $json->{metadata}->{depends}  &&
                                                           ref $json->{metadata}->{depends}  eq 'HASH');

  foreach my $scalar (qw/name version license/)
  {
   push @messages, "Missing or undefined metadata element $scalar" unless $json->{metadata}->{$scalar};
  }

  foreach my $array (qw/authors portfolio/)
  {
   push @messages, "Missing, invalid, or undefined metadata array $array" unless ($json->{metadata}->{$array} &&
                                                                                  ref $json->{metadata}->{$array} eq 'ARRAY');
  }

  unless (scalar @messages)
  {
   push @messages, "Portfolio metadata can't be empty" unless scalar @{$json->{metadata}->{portfolio}};
  }
 }

 # stage 4: check entry_point and interface
 unless (scalar @messages)
 {
  push @messages, "Missing entry_point" unless exists $json->{entry_point};
 }

 # entry_point has to point to a file in the manifest or be null
 unless (scalar @messages || !defined $json->{entry_point})
 {
  push @messages, "entry_point $json->{entry_point} not in manifest"
   unless exists $json->{manifest}->{$json->{entry_point}};
 }

 # we should not have any interface files that do NOT exist in the manifest
 unless (scalar @messages)
 {
  foreach (@{$json->{interface}})
  {
   push @messages, "interface file $_ not in manifest" unless exists $json->{manifest}->{$_};
  }
 }

 if (!scalar @messages) # there are no errors, so go on...
 {
  my $name = $json->{metadata}->{name};
  $json->{dir} = $config->fullpath || !is_resource_local($dir) ? $dir : File::Spec->abs2rel( $dir, $topdir );
  $json->{fulldir} = $dir;
  $json->{file} = $name;
  if ($noparse ||
      !defined $json->{entry_point} ||
      verify_entry_point($name, $json))
  {
   # note this name will be stringified even if it's not a string
   return $json;
  }
  else
  {
   Util::color_warn "Could not verify bundle entry point from $name" unless $quiet;
  }
 }
 else
 {
  Util::color_warn "Could not load sketch definition from $name: [@{[join '; ', @messages]}]" unless $quiet;
 }

 return undef;
}

# sub make_packages
# {
#  my $todo = shift @_;

#  my @dirs;

#  find(sub
#       {
#        my $f = $_;
#        if ($f =~ m/readme/i &&
#            read_yes_no(sprintf("Use directory %s (interesting file %s)?",
#                                $File::Find::dir,
#                                $File::Find::name),
#                        'n'))
#        {
#         push @dirs, $File::Find::dir;
#         $File::Find::prune = 1;
#        }
#       }, @$todo);

#       die "@dirs";
# }

sub verify_entry_point
{
 my $name = shift @_;
 my $data = shift @_;

 my $dir       = $data->{fulldir};
 my $mft       = $data->{manifest};
 my $entry     = $data->{entry_point};
 my $interface = $data->{interface};

 unless (defined $entry && defined $interface)
 {
  return undef;
 }

 my $maincf = $entry;

 my $maincf_filename = is_resource_local($dir) ? File::Spec->catfile($dir, $maincf) : "$dir/$maincf";

  my $meta = {
              file => basename($maincf_filename),
              dir => dirname($maincf_filename),
              fulldir => $dir,
              varlist => [
                         ],
             };

 my @mcf;
 my $mcf;

 if (exists $mft->{$maincf})
 {
  if (is_resource_local($dir))
  {
   unless (-f $maincf_filename)
   {
    Util::color_warn "Could not find sketch $name entry point '$maincf_filename'" unless $quiet;
    return 0;
   }

   unless (open($mcf, '<', $maincf_filename) && $mcf)
   {
    Util::color_warn "Could not open $maincf_filename: $!" unless $quiet;
    return 0;
   }
   @mcf = <$mcf>;
   $mcf = join "\n", @mcf;   # make sure the whole string is available
  }
  else
  {
   $mcf = lwp_get_remote($maincf_filename);
   unless ($mcf)
   {
    Util::color_warn "Could not retrieve $maincf_filename: $!" unless $quiet;
    return 0;
   }

   @mcf = split "\n", $mcf;
  }
 }

 my $tdir = tempdir( CLEANUP => 1 );
 my ($tfh, $tfilename) = tempfile( DIR => $tdir );

 if ($mcf !~ m/body\s+common\s+control.*bundlesequence/m)
 {
  print "Faking bundlesequence: collecting dependencies for $data->{metadata}->{name} from @{[sort keys %{$data->{metadata}->{depends}}]}\n"
   if $veryverbose;
  my %dependencies = map { $_ => 1 } collect_dependencies($data->{metadata}->{depends});
  my @inputs = collect_dependencies_inputs(dirname($tfilename), \%dependencies);
  print "Faking bundlesequence: collected inputs [@inputs]\n"
   if $veryverbose;
  my @p = recurse_print([ Util::uniq(@inputs) ]);
  $mcf = sprintf('
  body common control {

    bundlesequence => { "cf_null" };
    inputs => %s;
}
', $p[0]->{value}) . $mcf;
 }
 else
 {
 }

 # print "PARSING:\n$mcf\n\n" if $veryverbose;

 print $tfh $mcf;
 close $tfh;

 my $pb = cfengine_promises_binary();
 my $tline = "$pb --parse-tree";
 open my $parse, "$tline -f '$tfilename'|"
  or die "Could not run [$tline -f '$tfilename']: $!";

 my $ptree_str = join "\n", <$parse>;
 my $ptree;

 eval { $ptree = $coder->decode($ptree_str); };

 my @rejects;

 if ($ptree && exists $ptree->{bundles} && ref $ptree->{bundles} eq 'ARRAY')
 {
  my @bundles = @{$ptree->{bundles}};
  my $bnamespace;
  my $bname;
  my $bname_printable;
  my $bnamespace_printable;

  foreach my $bundle (grep { $_->{'bundle-type'} eq 'agent' } @bundles)
  {
   print "Looking at agent bundle $bundle->{name}\n"
    if $veryverbose;

   my @args = @{$bundle->{arguments}};
   ($bnamespace, $bname) = split ':', $bundle->{name};
   unless ($bname)
   {
    $bname = $bnamespace;
    undef $bnamespace;
   }

   $bnamespace_printable = $bnamespace || 'default';
   $bname_printable = "$bname (namespace=$bnamespace_printable)";
   print "Found bundle $bname_printable with args @args\n" if $verbose;

   # extract the variables.  start with a context called 'activated' by default
   my %vars = (
               activated => { type => 'CONTEXT', default => 'any' },
              );

   my %returns;

   foreach my $ptype (@{$bundle->{'promise-types'}})
   {
    print "Looking at promise type $ptype->{name}\n"
     if $veryverbose;

    next unless $ptype->{name} eq 'meta';
    foreach my $class (@{$ptype->{'classes'}})
    {
     print "Looking at class $class->{name}\n"
      if $veryverbose;

     if ($class->{name} eq 'any')
     {
      foreach my $promise (@{$class->{promises}})
      {
       print "Looking at 'any' meta promiser $promise->{promiser}\n"
        if $veryverbose;

       if ($promise->{promiser} =~ m/^vars\[([^]]+)\]\[(type|default)\]$/)
       {
        my ($var, $spec) = ($1, $2);

        print "Found promiser for var $var: $spec\n"
         if $veryverbose;

        if (exists $promise->{attributes}->[0]->{lval} &&
            exists $promise->{attributes}->[0]->{rval})
        {
         my $lval = $promise->{attributes}->[0]->{lval};
         my $rval = $promise->{attributes}->[0]->{rval};
         if ('string' eq $lval)
         {
          if ('string' eq $rval->{type})
          {
           $vars{$var}->{$spec} = $rval->{value};
          }
          elsif ('function-call' eq $rval->{type})
          {
           foreach my $farg (@{$rval->{arguments}})
           {
            next if $farg->{type} eq 'string';
            push @rejects, "Sorry, meta var promise $promise->{promiser} in bundle $bname_printable has a function call for a default with non-string argument $farg->{value}";
           }

           unless (scalar @rejects)
           {
            $vars{$var}->{$spec} = {
                                    function =>  $rval->{name},
                                    args => [map { $_->{value} } @{$rval->{arguments}}],
                                   };
           }
          }
          else
          {
           push @rejects, "Sorry, meta var promise $promise->{promiser} in bundle $bname_printable has invalid value type $rval->{type}";
          }
         }
         else
         {
          push @rejects, "Sorry, meta var promise $promise->{promiser} in bundle $bname_printable has invalid type $lval";
         }
        }
        else
        {
         push @rejects, "Sorry, promiser $promise->{promiser} in bundle $bname_printable is invalid";
        }
       }
       elsif ($promise->{promiser} =~ m/^returns\[([^]]+)\]$/)
       {
        my ($var) = ($1);

        print "Found promiser for returns $var\n"
         if $veryverbose;

        if (exists $promise->{attributes}->[0]->{lval} &&
            exists $promise->{attributes}->[0]->{rval})
        {
         my $lval = $promise->{attributes}->[0]->{lval};
         my $rval = $promise->{attributes}->[0]->{rval};
         if ('string' eq $lval)
         {
          if ('string' eq $rval->{type})
          {
           $returns{$var} = $rval->{value};
          }
          else
          {
           push @rejects, "Sorry, meta returns promise $promise->{promiser} in bundle $bname_printable has invalid value type $rval->{type}";
          }
         }
         else
         {
          push @rejects, "Sorry, meta var promise $promise->{promiser} in bundle $bname_printable has invalid type $lval";
         }
        }
        else
        {
         push @rejects, "Sorry, promiser $promise->{promiser} in bundle $bname_printable is invalid";
        }
       }
      }                                 # foreach promise
     }
     else
     {
      Util::color_warn "Sorry, we can't parse conditional ($class->{name}) meta promises in $bname_printable"
       if $verbose;
     }
    }
   }

   foreach my $var (sort keys %vars)
   {
    next if exists $vars{$var}->{type};
    push @rejects, "In $bname_printable, the meta definition for variable $var does not have a type (e.g. \"vars[umask][type]\" string => \"OCTAL\")";
   }

   foreach my $arg (@args)
   {
    if (exists $vars{$arg})
    {
     my $definition = {
                       name => $arg,
                       type => (exists $vars{$arg}->{type} ? $vars{$arg}->{type} : '???'),
                       passed => 1,
                      };

     $definition->{default} = $vars{$arg}->{default}
      if exists $vars{$arg}->{default};

     push @{$meta->{varlist}}, $definition;
     delete $vars{$arg};
    }
    else
    {
     push @rejects, "$bname_printable has argument $arg which is not defined as a meta promise (e.g. \"vars[umask][type]\" string => \"OCTAL\")";
    }
   }

   foreach my $var (sort keys %vars)
   {
    if ($vars{$var}->{type} eq 'CONTEXT')
    {
     my $definition = {
                       name => $var,
                       type => $vars{$var}->{type},
                       passed => 0,
                      };

     $definition->{default} = $vars{$var}->{default}
      if exists $vars{$var}->{default};

     push @{$meta->{varlist}}, $definition;
     delete $vars{$var};
    }
    else
    {
     push @rejects, "$bname_printable has a meta vars promise that does not correspond to a bundle argument";
    }
   }

   $meta->{returns} = \%returns;
   $meta->{bundle_name} = $bname;
   $meta->{bundle_namespace} = $bnamespace;
   last;                                # only try the first bundle!
  }

  unless ($bname)
  {
   push @rejects, "Couldn't find a usable bundle in $maincf_filename";
  }
 }
 else                                   # $ptree is not valid
 {
  if (length $ptree_str > 500)
  {
   $ptree_str = substr($ptree_str, 0, 500);
  }

  push @rejects, "Could not parse $maincf_filename with [$tline]: $ptree_str";
 }

 print "$maincf_filename bundle parse gave us " . Dumper($meta) if $veryverbose;

 if (scalar @rejects)
 {
  foreach (@rejects)
  {
   Util::color_warn $_ unless $quiet;
  }

  return undef;
 }

 return $meta;
}

sub is_resource_local
{
 my $resource = shift @_;
 return ($resource !~ m,^[a-z][a-z]+:,);
}

sub lwp_get_remote
{
 my $resource = shift @_;
 eval
 {
  require LWP::Simple;
 };
 if ($@ )
 {
  Util::color_die "Could not load LWP::Simple (you should install libwww-perl)";
 }

 if ($resource =~ m/^https/)
 {
  eval
  {
   require LWP::Protocol::https;
  };
  if ($@ )
  {
   Util::color_die "Could not load LWP::Protocol::https (you should install it)";
  }
 }

 return get($resource);
}

sub get_local_repo
{
 my $repo;
 foreach my $target (@{$config->repolist})
 {
  if (is_resource_local($target))
  {
   $repo = $target;
   last;
  }
 }
 return $repo;
}

{
 my %content_cache;
 sub repo_get_contents
 {
  my $repo = shift @_;
  my $noparse = shift @_ || 0;

  return $content_cache{$repo,$noparse}
   if exists $content_cache{$repo,$noparse};

  my $contents;
  if (is_resource_local($repo))
  {
   $contents = find_sketches([$repo], $noparse);
  }
  else
  {
   $contents = find_remote_sketches([$repo], $noparse);
  }

  $content_cache{$repo,$noparse} = $contents;
  return $contents;
 }
}

# Utility functions follow

sub load_json
{
 # TODO: improve this
 my $f = shift @_;
 my $local_quiet = shift @_;

 my @j;

 if (is_resource_local($f))
 {
  my $j;
  unless (open($j, '<', $f) && $j)
  {
   Util::color_warn "Could not inspect $f: $!" unless ($quiet || $local_quiet);
   return;
  }

  @j = <$j>;
 }
 else
 {
  my $j = lwp_get_remote($f)
   or Util::color_die "Unable to retrieve $f";

  @j = split "\n", $j;
 }

 if (scalar @j)
 {
  chomp @j;
  s/\n//g foreach @j;
  s/^\s*(#|\/\/).*//g foreach @j;
  my $ret = $coder->decode(join '', @j);

  if (ref $ret eq 'HASH' &&
      exists $ret->{include} && ref $ret->{include} eq 'ARRAY')
  {
   foreach my $include (@{$ret->{include}})
   {
    if (dirname($include) eq '.' && ! -f $include)
    {
      if (is_resource_local($f)) {
        $include = File::Spec->catfile(dirname($f), $include);
      }
      else {
        $include = dirname($f)."/$include";
      }
    }

    print "Including $include\n" unless $quiet;
    my $parent = load_json($include);
    if (ref $parent eq 'HASH')
    {
     $ret->{$_} = $parent->{$_} foreach keys %$parent;
    }
    else
    {
     Util::color_warn "Malformed include contents from $include: not a hash" unless $quiet;
    }
   }
   delete $ret->{include};
  }

  return $ret;
 }

 return;
}

sub ensure_dir
{
 my $dir = shift @_;

 make_path($dir, { verbose => $verbose });
 return -d $dir;
}

sub remove_dir
{
 my $dir = shift @_;

 return remove_tree($dir, { verbose => $verbose });
}

sub maybe_ensure_dir
{
   if ($dryrun)
   {
    print YELLOW "DRYRUN: will not ensure/create directory $_[0]\n";
    return 1;
   }

   return ensure_dir($_[0]);
}

sub maybe_remove_dir
{
   if ($dryrun)
   {
    print YELLOW "DRYRUN: will not remove directory $_[0]\n";
    return 1;
   }

   return remove_dir($_[0]);
}

sub maybe_write_file
{
 my $file = shift @_;
 my $desc = shift @_;
 my $data = shift @_;

 if ($dryrun)
 {
  print YELLOW "DRYRUN: will not write $desc file $file with data\n$data";
 }
 else
 {
  open(my $fh, '>', $file)
   or Util::color_die "Could not write $desc file $file: $!";

  print $fh $data;
  close $fh;
 }
}


{
 my $promises_binary;

 sub cfengine_promises_binary
 {
  my $promises_name = 'cf-promises';

  unless ($promises_binary)
  {
   foreach my $check_path (split ':', $config->cfpath)
   {
    my $check = "$check_path/$promises_name";
    $promises_binary = $check if -x $check;
    last if $promises_binary;
   }
  }

  Util::color_die "Sorry, but we couldn't find $promises_name in the search path $config->cfpath.  Please set \$PATH or use the --cfpath parameter!"
   unless $promises_binary;

  print "Excellent, we found $promises_binary to interface with CFEngine\n"
   if $veryverbose;

  return $promises_binary;
 }

 sub cfengine_version
 {
  my $pb = cfengine_promises_binary();
  my $cfv = `$pb -V`;     # TODO: get this from cfengine?
  if ($cfv =~ m/\s+(\d+\.\d+\.\d+)/)
  {
   return $1;
  }
  else
  {
   print YELLOW "Unsatisfied cfengine dependency: could not get version from [$cfv].\n"
    if $verbose;
   return 0;
  }
 }
}

sub is_json_boolean
{
 return ((ref shift) =~ m/JSON.*Boolean/);
}

sub recurse_print
{
 my $ref             = shift @_;
 my $prefix          = shift @_;
 my $unquote_scalars = shift @_;
 my $simplify_arrays = shift @_;

 my @print;

 # recurse for hashes
 if (ref $ref eq 'HASH')
 {
  if (exists $ref->{function} && exists $ref->{args})
  {
   push @print, {
                 path => $prefix,
                 type => 'string',
                 value => sprintf('%s(%s)',
                                  $ref->{function},
                                  join(', ', map { my @p = recurse_print($_); $p[0]->{value} } @{$ref->{args}}))
                };
  }
  else
  {
   # warn Dumper [ $ref            ,
   #              $prefix         ,
   #              $unquote_scalars,
   #              $simplify_arrays];
   push @print, recurse_print($ref->{$_},
                              sprintf("%s%s",
                                      ($prefix||''),
                                      $simplify_arrays ? "_${_}" : "[$_]"),
                              $unquote_scalars,
                              0)
    foreach sort keys %$ref;
  }
 }
 elsif (ref $ref eq 'ARRAY')
 {
  my $joined;

  if (scalar @$ref)
  {
   $joined = sprintf('{ %s }',
                     join(", ",
                          map { s,\\,\\\\,g; s,",\\",g; "\"$_\"" } @$ref));
  }
  else
  {
   $joined = '{ "cf_null" }';
  }

  push @print, {
                path => $prefix,
                type => 'slist',
                value => $joined
               };
 }
 else
 {
  # convert to a 1/0 boolean
  $ref = ! ! $ref if is_json_boolean($ref);
  push @print, {
                path => $prefix,
                type => 'string',
                value => $unquote_scalars ? $ref : "\"$ref\""
               };
 }

 return @print;
}

sub collect_dependencies
{
 my $deps = shift @_;

 my @collected;

 foreach my $repo (@{$config->repolist})
 {
  my $contents = repo_get_contents($repo, 1);
  foreach my $dep (sort keys %$deps)
  {
   if ($dep eq 'os' || $dep eq 'cfengine')
   {
   }
   elsif (exists $contents->{$dep})
   {
    my $dd = $contents->{$dep};
    print "Checking dependency match $dep in $repo: " . $coder->encode($dd) . "\n" if $veryverbose;
    # either the version is not specified or it has to match
    if (!exists $deps->{$dep}->{version} ||
        $dd->{metadata}->{version} >= $deps->{$dep}->{version})
    {
     print "Found dependency $dep in $repo\n" if $veryverbose;
     # TODO: test recursive dependencies, right now this will loop
     # TODO: maybe use a CPAN graph module
     push @collected, $dep, collect_dependencies($dd->{metadata}->{depends});
    }
    else
    {
     print YELLOW "Found dependency $dep in $repo but the version doesn't match\n"
      if $verbose;
    }
   }
  }
 }

 return @collected;
}

sub collect_dependencies_inputs
{
 my $install_dir = shift @_;
 my $dep_map     = shift @_;

 my @inputs;
 foreach my $repo (@{$config->repolist})
 {
  my $contents = repo_get_contents($repo, 1);
  foreach my $dep (keys %$dep_map)
  {
   if (exists $contents->{$dep})
   {
    my $input = make_include($contents->{$dep}->{fulldir}, $install_dir , @{$contents->{$dep}->{interface}});
    push @inputs, $input;
    delete $dep_map->{$dep};
   }
  }
 }

 return @inputs;
}

sub make_include_path
{
 my $lib_dir = shift @_;
 my $run_dir = shift @_;

 return $config->fullpath ? $lib_dir : File::Spec->abs2rel($lib_dir, $run_dir );
}

sub make_include
{
 my $lib_dir = shift @_;
 my $run_dir = shift @_;
 my $file = shift @_;

 my $dir = make_include_path($lib_dir, $run_dir);
 my $input = File::Spec->catfile($dir, $file);
}

sub make_runfile
{
 my $activations = shift @_;
 my $inputs      = shift @_;
 my $standalone  = shift @_;
 my $target_file = shift @_;

 my $template = get_run_template();

 my $contexts = '';
 my $vars     = '';
 my $methods  = '';
 my $commoncontrol = '';

 if ($standalone)
 {
  $commoncontrol=<<'EOHIPPUS';
body common control
{
      bundlesequence => { "cfsketch_run" };
      inputs => { @(cfsketch_g.inputs) };
}
EOHIPPUS
 }

 foreach my $a (keys %$activations)
 {
  $contexts .= "       # contexts for activation $a\n";
  $vars .= "       # string and slist variables for activation $a\n";
  my $act = $activations->{$a};
  my @vars = @{$activations->{$a}->{vars}};
  my %params = %{$activations->{$a}->{pdata}};
  my @passed;

  my $rel_path = make_include_path($act->{fulldir}, dirname($target_file));

  my $current_context = '';
  # die Dumper \@vars;
  foreach my $var (@vars)
  {
   my $name = $var->{name};
   my $value = exists $params{$name} ? $params{$name} :  $var->{value};

   if (ref $value eq '')
   {
    # for when a bundle wants access to scripts or modules
    $value =~ s/__BUNDLE_HOME__/$rel_path/g;
    $value =~ s/__ABS_BUNDLE_HOME__/$act->{fulldir}/g;
    # for when a bundle wants access to the general variables directly
    $value =~ s/__PREFIX__/cfsketch_g._${a}_$act->{prefix}_/g;
    # for when a bundle wants to access its activation's classes
    $value =~ s/__CLASS_PREFIX__/default:_${a}_$act->{prefix}_/g;
    # for when a bundle wants to set unique classes per activation
    $value =~ s/__CANON_PREFIX__/_${a}_$act->{prefix}_/g;
   }

   push @passed, [ $var, $value ]
    if (exists $var->{passed} && $var->{passed});

   my %bycontext;
   if (ref $value eq 'HASH' &&
       exists $value->{bycontext} &&
       ref $value->{bycontext} eq 'HASH')
   {
    %bycontext = %{$value->{bycontext}};
   }
   else
   {
    $bycontext{any} = $value;
   }

   foreach my $context (sort keys %bycontext)
   {
    if ($var->{type} eq 'CONTEXT')
    {
     my $as_cfengine_context = $bycontext{$context};
     if (is_json_boolean($bycontext{$context}))
     {
      $as_cfengine_context = $bycontext{$context} ? 'any' : "!any";
     }
     elsif (ref $as_cfengine_context ne '')
     {
      Util::color_die "Unexpected value for CONTEXT $name: " . $coder->encode($as_cfengine_context);
     }

     $contexts .= "     ${context}::\n" if $current_context ne $context;
     $current_context = $context;
     $contexts .= sprintf('      "_%s_%s_%s" expression => "%s";' . "\n",
                          $a,
                          $act->{prefix},
                          $name,
                          $as_cfengine_context);

     my $print_context = $as_cfengine_context;
     $vars .= "     ${print_context}:: # setting context for text representations\n" if $current_context ne $print_context;
     $current_context = $print_context;
     $vars .= sprintf('       "_%s_%s_contexts[%s]" string => "%s"; # text representation of the context "%s"' . "\n",
                      $a,
                      $act->{prefix},
                      $name,
                      $bycontext{$context},
                      $name);

     if ($name eq 'activated')
     {
      $methods .= sprintf('    _%s_%s_%s::' . "\n",
                          $a,
                          $act->{prefix},
                          $name);
     }
    }
    else                                # regular, non-CONTEXT variable
    {
     $vars .= "     ${context}::\n" if $current_context ne $context;
     $current_context = $context;

     my @p = recurse_print($bycontext{$context},
                           "_${a}_$act->{prefix}_${name}",
                           0,
                           $config->simplify_arrays );
     $vars .= sprintf('       "%s" %s => %s;' . "\n",
                      $_->{path},
                      $_->{type},
                      $_->{value})
      foreach @p;
    }
   }

   Util::color_die("Sorry, but we have an undefined variable $name: it has neither a parameter value nor a supplied value")
    unless defined $value;
  }

  print "We will activate bundle $act->{entry_bundle} with passed parameters " . $coder->encode(\@passed) . "\n"
   if $verbose;

  my @print_passed;
  foreach my $pass (@passed)
  {
   my $var = $pass->[0];
   if ($var->{type} =~ m/^(KV)?ARRAY\(/)
   {
    push @print_passed, "\"default:cfsketch_g._${a}_$act->{prefix}_$var->{name}\"";
   }
   else
   {
    my $islist = $var->{type} =~ m/^LIST\(/;
    my $sigil = $islist ? '@' : '$';
    # my $maybe_quotes = $islist ? '"' : '';
    my $maybe_quotes = '';
    push @print_passed, "$maybe_quotes$sigil(cfsketch_g._${a}_$act->{prefix}_$var->{name})$maybe_quotes";
   }
  }

  my $args = join(", ", @print_passed);

  $methods .= sprintf('      "%s %s %s" usebundle => %s%s(%s);' . "\n",
                      $a,
                      $act->{sketch},
                      $act->{activation_id},
                      $act->{entry_bundle_namespace} ? "$act->{entry_bundle_namespace}:" : '',
                      $act->{entry_bundle},
                      $args);
 }

 $template =~ s/__INPUTS__/$inputs/g;
 $template =~ s/__CONTEXTS__/$contexts/g;
 $template =~ s/__VARS__/$vars/g;
 $template =~ s/__METHODS__/$methods/g;
 $template =~ s/__COMMONCONTROL__/$commoncontrol/g;

 return $template;
}

sub get_run_template
{
 return <<'EOT';
__COMMONCONTROL__

bundle common cfsketch_g
{
  classes:
      # contexts
__CONTEXTS__
  vars:
       # Files that need to be loaded for this to work.
       "inputs" slist => { __INPUTS__ };

__VARS__
}

bundle agent cfsketch_run
{
  methods:
      "cfsketch_g" usebundle => "cfsketch_g";
__METHODS__
}
EOT
}

sub tersedump
{
  local $Data::Dumper::Terse = 1;
  local $Data::Dumper::Indent = 0;
  return Dumper(shift);
}

sub validate
{
 my $value = shift @_;
 my @validation_types = @_;

 # null values are never valid
 return undef unless defined $value;

 if (ref $value eq 'HASH' &&
     exists $value->{bycontext} &&
     ref $value->{bycontext} eq 'HASH')
 {
  my $ret = 1;
  foreach my $context (sort keys %{$value->{bycontext}})
  {
   my $ret2k = validate($context, "CONTEXT");
   Util::color_warn("Validation failed in bycontext, context key $context")
    unless $ret2k;
   my $val2 = $value->{bycontext}->{$context};
   my $ret2v = validate($val2, @validation_types);

   Util::color_warn("Validation failed in bycontext VALUE '$val2', key $context, validation types [@validation_types]")
    unless $ret2v;

   $ret &&= $ret2k && $ret2v;
  }

  return $ret;
 }

 if (ref $value eq 'ARRAY')
 {
  my $vt = $validation_types[0];
  return undef unless $vt;
  return undef unless $vt =~ m/^LIST\((.+)\)$/s;

  my $subtype = $1;
  my $ret = 1;
  foreach my $subval (@$value)
  {
   my $ret2 = validate($subval, $subtype);
   Util::color_warn("LIST validation failed in bycontext, VALUE '$subval'")
    unless $ret2;

   $ret &&= $ret2;
  }

  return $ret;
 }

 my $good = 0;
 foreach my $vtype (@validation_types)
 {
  if ($vtype =~ m/^(KV)?ARRAY\(\n*(.*)\n*\s*\)/s)
  {
   if (ref $value ne 'HASH')
   {
    Util::color_warn("Sorry, but ARRAY validation was requested on a non-array value '$value'.  We'll fail the validation.");
    return undef;
   }

   my $kv = $1;
   my %contents = ($2 =~ m/^([^:\s]+)\s*:\s*(.+?)$/mg);

   $good = 1;

   my $kv_key;

   if ($kv)
   {
    $kv_key = '_key';
    foreach my $k (sort keys %$value)
    {
     my $goodk = validate($k, $contents{$kv_key});
     Util::color_warn("Sorry, but KVARRAY validation failed for K '$k' with type '$contents{$kv_key}'.  We'll fail the validation.")
      unless $goodk;
     $good &&= $goodk;
    }
   }

   foreach my $process_key ($kv ? (sort keys %$value) : (1))
   {
    my $process_value = $kv ? $value->{$process_key} : $value;

    if (ref $process_value ne 'HASH')   # this check is necessary only when $kv
    {
     Util::color_warn("Sorry, but KVARRAY validation was requested on a non-array entry value '$process_value'.  We'll fail the validation.");
     return undef;
    }

    foreach my $key (sort keys %contents)
    {
     next if (defined $kv_key && $key eq $kv_key);

     my $check_value = $process_value->{$key};

     my $subtype = $contents{$key};
     my $required = 0;

     if ($subtype =~ m/(.+):\s*required/)
     {
      $subtype = $1;
      $required = 1;
     }
     elsif ($subtype =~ m/(.+):\s*default=(.*)/)
     {
      $subtype = $1;
      $process_value->{$key} = $2
        unless exists $process_value->{$key};
     }

     if ($required || defined $check_value)
     {
      my $good2 = validate($check_value, $subtype);

      unless ($good2)
      {
       Util::color_warn("ARRAY validation: value '$check_value', subtype '$subtype', subkey '$process_key'.  We'll fail the validation.")
        if $verbose;
      }

      $good &&= $good2;
     }
    }
   }
  }
  elsif ($vtype eq 'PATH')
  {
   $good ||= $value =~ m,^/,;            # fails on Win32
  }
  elsif ($vtype eq 'CONTEXT')
  {
   $good ||= $value =~ m/^[\w!.|&()]+$/;
  }
  elsif ($vtype eq 'OCTAL')
  {
   $good ||= $value =~ m/^[0-7]+$/;
  }
  elsif ($vtype eq 'DIGITS')
  {
   $good ||= $value =~ m/^[0-9]+$/;
  }
  elsif ($vtype eq 'IPv4_ADDRESS')
  {
   $good ||= ($value =~ m/^(\d+)\.(\d+)\.(\d+)\.(\d+)+$/ &&
              $1 >= 0 && $1 <= 255 &&
              $2 >= 0 && $2 <= 255 &&
              $3 >= 0 && $3 <= 255 &&
              $4 >= 0 && $4 <= 255);
  }
  elsif ($vtype eq 'BOOLEAN')
  {
   $good ||= $value =~ m/^(true|false|on|off|1|0)$/i;
  }
  elsif ($vtype eq 'NON_EMPTY_STRING')
  {
   $good ||= length $value;
  }
  elsif ($vtype eq 'CONTEXT_NAME')
  {
   $good ||= $value !~ m/\W/;
  }
  elsif ($vtype eq 'STRING')
  {
   $good ||= defined $value;
  }
  elsif ($vtype eq 'HTTP_URL')
  {
   $good ||= $value =~ m,^(git|https?)://.+,; # this is not a good URL regex
  }
  elsif ($vtype eq 'FILE_URL')
  {
   $good ||= $value =~ m,^(file):///.+,; # this is not a good URL regex
  }
  elsif ($vtype eq 'FTP_URL')
  {
   $good ||= $value =~ m,^(ftp)://.+,; # this is not a good URL regex
  }
  elsif ($vtype =~  m/\|/)
  {
   $good = 0;
   foreach my $subtype (split('\|',$vtype))
   {
    my $good2 = validate($value, $subtype);
    $good ||= $good2;
   }
  }
  elsif ($vtype =~ m/^=(.+)/)
  {
   $good ||= $value eq $1;
  }
  else
  {
   Util::color_warn("Sorry, but an unknown validation type $vtype was requested.  We'll fail the validation, too.");
   return undef;
  }

  return 1 if $good;
 }

 return 0;
}

sub search
{
 my $terms = shift @_;
 my $source = $config->installsource;
 my $base_dir = dirname($source);
 my $search = search_internal($source, []);
 my $local_dir = is_resource_local($base_dir);

 SKETCH:
 foreach my $sketch (sort keys %{$search->{known}})
 {
  my $dir = $local_dir ? File::Spec->catdir($base_dir, $search->{known}->{$sketch}) : "$base_dir/$search->{known}->{$sketch}";
  foreach my $term (@$terms)
  {
   if ($sketch =~ m/$term/i || $dir =~ m/$term/i)
   {
    print GREEN, "$sketch", RESET, " $dir\n";
    next SKETCH;
   }
  }
 }
}

sub search_internal
{
 my $source = shift @_;
 my $sketches = shift @_;

 my %known;
 my %todo;
 my $local_dir = is_resource_local($source);

 if ($local_dir)
 {
  Util::color_die "cf-sketch inventory source $source must be a file"
   unless -f $source;

  open(my $invf, '<', $source)
   or Util::color_die "Could not open cf-sketch inventory file $source: $!";

  while (<$invf>)
  {
   my $line = $_;

   my ($dir, $sketch, $etc) = (split ' ', $line, 3);
   $known{$sketch} = $dir;

   foreach my $s (@$sketches)
   {
    next unless ($sketch eq $s || $dir eq $s);
    $todo{$sketch} = $dir;
   }
  }
 }
 else
 {
  my $invd = lwp_get_remote($source)
   or Util::color_die "Unable to retrieve $source : $!\n";

  my @lines = split "\n", $invd;
  foreach my $line (@lines)
  {
   my ($dir, $sketch, $etc) = (split ' ', $line, 3);
   $known{$sketch} = $dir;

   foreach my $s (@$sketches)
   {
    next unless ($sketch eq $s || $dir eq $s);
    $todo{$sketch} = $dir;
   }
  }
 }

 return { known => \%known, todo => \%todo };
}
