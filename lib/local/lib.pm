use strict;
use warnings;

package local::lib;

use 5.008001; # probably works with earlier versions but I'm not supporting them
              # (patches would, of course, be welcome)

use File::Spec ();
use File::Path ();
use Carp ();
use Config;

our $VERSION = '1.004001'; # 1.4.1

sub import {
  my ($class, @args) = @_;

  # The path is required, but last in the list, so we pop, not shift here. 
  my $path = pop @args;
  $path = $class->resolve_path($path);
  $class->setup_local_lib_for($path);

  # Handle the '--self-contained' option
  my $flag = shift @args;  
  no warnings 'uninitialized'; # the flag is optional 
  # make sure fancy dashes cause an error
  if ($flag =~ /−/) {
      die <<'DEATH';
WHOA THERE! It looks like you've got some fancy dashes in your commandline!
These are *not* the traditional -- dashes that software recognizes. You
probably got these by copy-pasting from the perldoc for this module as
rendered by a UTF8-capable formatter. This most typically happens on an OS X
terminal, but can happen elsewhere too. Please try again after replacing the
dashes with normal minus signs.
DEATH
  }
  if ($flag eq '--self-contained') {
    # The only directories that remain are those that we just defined and those where core modules are stored. 
    @INC = ($Config::Config{privlibexp}, $Config::Config{archlibexp}, split ':', $ENV{PERL5LIB});
  }
  elsif (defined $flag) {
      die "unrecognized import argument: $flag";
  }

}

sub pipeline;

sub pipeline {
  my @methods = @_;
  my $last = pop(@methods);
  if (@methods) {
    \sub {
      my ($obj, @args) = @_;
      $obj->${pipeline @methods}(
        $obj->$last(@args)
      );
    };
  } else {
    \sub {
      shift->$last(@_);
    };
  }
}

=begin testing

#:: test pipeline

package local::lib;

{ package Foo; sub foo { -$_[1] } sub bar { $_[1]+2 } sub baz { $_[1]+3 } }
my $foo = bless({}, 'Foo');                                                 
Test::More::ok($foo->${pipeline qw(foo bar baz)}(10) == -15);

=end testing

=cut

sub resolve_path {
  my ($class, $path) = @_;
  $class->${pipeline qw(
    resolve_relative_path
    resolve_home_path
    resolve_empty_path
  )}($path);
}

sub resolve_empty_path {
  my ($class, $path) = @_;
  if (defined $path) {
    $path;
  } else {
    '~/perl5';
  }
}

=begin testing

#:: test classmethod setup

my $c = 'local::lib';

=end testing

=begin testing

#:: test classmethod

is($c->resolve_empty_path, '~/perl5');
is($c->resolve_empty_path('foo'), 'foo');

=end testing

=cut

sub resolve_home_path {
  my ($class, $path) = @_;
  return $path unless ($path =~ /^~/);
  my ($user) = ($path =~ /^~([^\/]+)/); # can assume ^~ so undef for 'us'
  my $tried_file_homedir;
  my $homedir = do {
    if (eval { require File::HomeDir } && $File::HomeDir::VERSION >= 0.65) {
      $tried_file_homedir = 1;
      if (defined $user) {
        File::HomeDir->users_home($user);
      } else {
        File::HomeDir->my_home;
      }
    } else {
      if (defined $user) {
        (getpwnam $user)[7];
      } else {
        if (defined $ENV{HOME}) {
          $ENV{HOME};
        } else {
          (getpwuid $<)[7];
        }
      }
    }
  };
  unless (defined $homedir) {
    Carp::croak(
      "Couldn't resolve homedir for "
      .(defined $user ? $user : 'current user')
      .($tried_file_homedir ? '' : ' - consider installing File::HomeDir')
    );
  }
  $path =~ s/^~[^\/]*/$homedir/;
  $path;
}

sub resolve_relative_path {
  my ($class, $path) = @_;
  File::Spec->rel2abs($path);
}

=begin testing

#:: test classmethod

local *File::Spec::rel2abs = sub { shift; 'FOO'.shift; };
is($c->resolve_relative_path('bar'),'FOObar');

=end testing

=cut

sub setup_local_lib_for {
  my ($class, $path) = @_;
  $class->ensure_dir_structure_for($path);
  if ($0 eq '-') {
    $class->print_environment_vars_for($path);
    exit 0;
  } else {
    $class->setup_env_hash_for($path);
    unshift(@INC, split(':', $ENV{PERL5LIB}));
  }
}

sub modulebuildrc_path {
  my ($class, $path) = @_;
  File::Spec->catfile($path, '.modulebuildrc');
}

sub install_base_bin_path {
  my ($class, $path) = @_;
  File::Spec->catdir($path, 'bin');
}

sub install_base_perl_path {
  my ($class, $path) = @_;
  File::Spec->catdir($path, 'lib', 'perl5');
}

sub install_base_arch_path {
  my ($class, $path) = @_;
  File::Spec->catdir($class->install_base_perl_path($path), $Config{archname});
}

sub ensure_dir_structure_for {
  my ($class, $path) = @_;
  unless (-d $path) {
    warn "Attempting to create directory ${path}\n";
  }
  File::Path::mkpath($path);
  my $modulebuildrc_path = $class->modulebuildrc_path($path);
  if (-e $modulebuildrc_path) {
    unless (-f _) {
      Carp::croak("${modulebuildrc_path} exists but is not a plain file");
    }
  } else {
    warn "Attempting to create file ${modulebuildrc_path}\n";
    open MODULEBUILDRC, '>', $modulebuildrc_path
      || Carp::croak("Couldn't open ${modulebuildrc_path} for writing: $!");
    print MODULEBUILDRC qq{install  --install_base  ${path}\n}
      || Carp::croak("Couldn't write line to ${modulebuildrc_path}: $!");
    close MODULEBUILDRC
      || Carp::croak("Couldn't close file ${modulebuildrc_path}: $@");
  }
}

sub INTERPOLATE_ENV () { 1 }
sub LITERAL_ENV     () { 0 }

sub print_environment_vars_for {
  my ($class, $path) = @_;
  my @envs = $class->build_environment_vars_for($path, LITERAL_ENV);
  my $out = '';

  # rather basic csh detection, goes on the assumption that something won't
  # call itself csh unless it really is. also, default to bourne in the
  # pathological situation where a user doesn't have $ENV{SHELL} defined.
  # note also that shells with funny names, like zoid, are assumed to be
  # bourne.
  my $shellbin = 'sh';
  if(defined $ENV{'SHELL'}) {
      my @shell_bin_path_parts = File::Spec->splitpath($ENV{'SHELL'});
      $shellbin = $shell_bin_path_parts[-1];
  }
  my $shelltype = do {
      local $_ = $shellbin;
      if(/csh/) {
          'csh'
      } else {
          'bourne'
      }
  };

  while (@envs) {
    my ($name, $value) = (shift(@envs), shift(@envs));
    $value =~ s/(\\")/\\$1/g;
    $out .= $class->${\"build_${shelltype}_env_declaration"}($name, $value);
  }
  print $out;
}

# simple routines that take two arguments: an %ENV key and a value. return
# strings that are suitable for passing directly to the relevant shell to set
# said key to said value.
sub build_bourne_env_declaration {
  my $class = shift;
  my($name, $value) = @_;
  return qq{export ${name}="${value}"\n};
}

sub build_csh_env_declaration {
  my $class = shift;
  my($name, $value) = @_;
  return qq{setenv ${name} "${value}"\n};
}

sub setup_env_hash_for {
  my ($class, $path) = @_;
  my %envs = $class->build_environment_vars_for($path, INTERPOLATE_ENV);
  @ENV{keys %envs} = values %envs;
}

sub build_environment_vars_for {
  my ($class, $path, $interpolate) = @_;
  return (
    MODULEBUILDRC => $class->modulebuildrc_path($path),
    PERL_MM_OPT => "INSTALL_BASE=${path}",
    PERL5LIB => join(':',
                  $class->install_base_perl_path($path),
                  $class->install_base_arch_path($path),
                  ($ENV{PERL5LIB} ?
                    ($interpolate == INTERPOLATE_ENV
                      ? ($ENV{PERL5LIB})
                      : ('$PERL5LIB'))
                    : ())
                ),
    PATH => join(':',
              $class->install_base_bin_path($path),
              ($interpolate == INTERPOLATE_ENV
                ? $ENV{PATH}
                : '$PATH')
             ),
  )
}

=begin testing

#:: test classmethod

File::Path::rmtree('t/var/splat');

$c->ensure_dir_structure_for('t/var/splat');

ok(-d 't/var/splat');

ok(-f 't/var/splat/.modulebuildrc');

=end testing

=head1 NAME

local::lib - create and use a local lib/ for perl modules with PERL5LIB

=head1 SYNOPSIS

In code -

  use local::lib; # sets up a local lib at ~/perl5

  use local::lib '~/foo'; # same, but ~/foo

  # Or...
  use FindBin;
  use local::lib "$FindBin::Bin/../support";  # app-local support library

From the shell -

  # Install LWP and it's missing dependencies to the 'my_lwp' directory
  perl -MCPAN -Mlocal::lib=my_lwp -e 'CPAN::install(LWP)'

  # Install LWP and *all non-core* dependencies to the 'my_lwp' directory 
  perl -MCPAN -Mlocal::lib=--self-contained,my_lwp -e 'CPAN::install(LWP)'

  # Just print out useful shell commands
  $ perl -Mlocal::lib
  export MODULEBUILDRC=/home/username/perl/.modulebuildrc
  export PERL_MM_OPT='INSTALL_BASE=/home/username/perl'
  export PERL5LIB='/home/username/perl/lib/perl5:/home/username/perl/lib/perl5/i386-linux'
  export PATH="/home/username/perl/bin:$PATH"

To bootstrap if you don't have local::lib itself installed -

  <download local::lib tarball from CPAN, unpack and cd into dir>

  $ perl Makefile.PL --bootstrap
  $ make test && make install

  $ echo 'eval $(perl -I$HOME/perl5/lib/perl5 -Mlocal::lib)' >>~/.bashrc

  # Or for C shells...

  $ /bin/csh
  % echo $SHELL
  /bin/csh
  % perl -I$HOME/perl5/lib/perl5 -Mlocal::lib >> ~/.cshrc

You can also pass --boostrap=~/foo to get a different location -

  $ perl Makefile.PL --bootstrap=~/foo
  $ make test && make install

  $ echo 'eval $(perl -I$HOME/foo/lib/perl5 -Mlocal::lib=$HOME/foo)' >>~/.bashrc

If you want to install multiple Perl module environments, say for application evelopment, 
install local::lib globally and then:

    $ cd ~/mydir1
    $ perl -Mlocal::lib=./
    $ eval $(perl -Mlocal::lib=./)  ### To set the environment for this shell alone
    $ printenv  ### You will see that ~/mydir1 is in the PERL5LIB
    $ perl -MCPAN -e install ...    ### whatever modules you want
    $ cd ../mydir2
    ... REPEAT ...

For multiple environments for multiple apps you may need to include a modified version of 
the C<< use FindBin >> instructions in the "In code" sample above. If you did something like
the above, you have a set of Perl modules at C<< ~/mydir1/lib >>. If you have a script at
C<< ~/mydir1/scripts/myscript.pl >>, you need to tell it where to find the modules you installed 
for it at C<< ~/mydir1/lib >>.

In C<< ~/mydir1/scripts/myscript.pl >>:

    use strict;
    use warnings;
    use local::lib "$FindBin::Bin/..";  ### points to ~/mydir1 and local::lib finds lib
    use lib "$FindBin::Bin/../lib";     ### points to ~/mydir1/lib

Put this before any BEGIN { ... } blocks that require the modules you installed.

=head1 DESCRIPTION

This module provides a quick, convenient way of bootstrapping a user-local Perl
module library located within the user's home directory. It also constructs and
prints out for the user the list of environment variables using the syntax
appropriate for the user's current shell (as specified by the C<SHELL>
environment variable), suitable for directly adding to one's shell configuration
file.

More generally, local::lib allows for the bootstrapping and usage of a directory
containing Perl modules outside of Perl's C<@INC>. This makes it easier to ship
an application with an app-specific copy of a Perl module, or collection of
modules. Useful in cases like when an upstream maintainer hasn't applied a patch
to a module of theirs that you need for your application.

On import, local::lib sets the following environment variables to appropriate
values:

=over 4

=item MODULEBUILDRC

=item PERL_MM_OPT

=item PERL5LIB

=item PATH

PATH is appended to, rather than clobbered.

=back

These values are then available for reference by any code after import.

=head1 METHODS

=head2 ensure_directory_structure_for

=over 4

=item Arguments: path

=back

Attempts to create the given path, and all required parent directories. Throws
an exception on failure.

=head2 print_environment_vars_for

=over 4

=item Arguments: path

=back

Prints to standard output the variables listed above, properly set to use the
given path as the base directory.

=head2 setup_env_hash_for

=over 4

=item Arguments: path

=back

Constructs the C<%ENV> keys for the given path, by calling
C<build_environment_vars_for>.

=head2 install_base_perl_path

=over 4

=item Arguments: path

=back

Returns a path describing where to install the Perl modules for this local
library installation. Appends the directories C<lib> and C<perl5> to the given
path.

=head2 install_base_arch_path

=over 4

=item Arguments: path

=back

Returns a path describing where to install the architecture-specific Perl
modules for this local library installation. Based on the
L</install_base_perl_path> method's return value, and appends the value of
C<$Config{archname}>.

=head2 install_base_bin_path

=over 4

=item Arguments: path

=back

Returns a path describing where to install the executable programs for this
local library installation. Based on the L</install_base_perl_path> method's
return value, and appends the directory C<bin>.

=head2 modulebuildrc_path

=over 4

=item Arguments: path

=back

Returns a path describing where to install the C<.modulebuildrc> file, based on
the given path.

=head2 resolve_empty_path

=over 4

=item Arguments: path

=back

Builds and returns the base path into which to set up the local module
installation. Defaults to C<~/perl5>.

=head2 resolve_home_path

=over 4

=item Arguments: path

=back

Attempts to find the user's home directory. If installed, uses C<File::HomeDir>
for this purpose. If no definite answer is available, throws an exception.

=head2 resolve_relative_path

=over 4

=item Arguments: path

=back

Translates the given path into an absolute path.

=head2 resolve_path

=over 4

=item Arguments: path

=back

Calls the following in a pipeline, passing the result from the previous to the
next, in an attempt to find where to configure the environment for a local
library installation: L</resolve_empty_path>, L</resolve_home_path>,
L</resolve_relative_path>. Passes the given path argument to
L</resolve_empty_path> which then returns a result that is passed to
L</resolve_home_path>, which then has its result passed to
L</resolve_relative_path>. The result of this final call is returned from
L</resolve_path>.

=head1 A WARNING ABOUT UNINST=1

Be careful about using local::lib in combination with "make install UNINST=1".
The idea of this feature is that will uninstall an old version of a module
before installing a new one. However it lacks a safety check that the old
version and the new version will go in the same directory. Used in combination
with local::lib, you can potentially delete a globally accessible version of a
module while installing the new version in a local place. Only combine "make
install UNINST=1" and local::lib if you understand these possible consequences.

=head1 LIMITATIONS

Rather basic shell detection. Right now anything with csh in its name is
assumed to be a C shell or something compatible, and everything else is assumed
to be Bourne. If the C<SHELL> environment variable is not set, a
Bourne-compatible shell is assumed.

Bootstrap is a hack and will use CPAN.pm for ExtUtils::MakeMaker even if you
have CPANPLUS installed.

Kills any existing PERL5LIB, PERL_MM_OPT or MODULEBUILDRC.

Should probably auto-fixup CPAN config if not already done.

Patches very much welcome for any of the above.

=head1 TROUBLESHOOTING

If you've configured local::lib to install CPAN modules somewhere in to your
home directory, and at some point later you try to install a module with C<cpan
-i Foo::Bar>, but it fails with an error like: C<Warning: You do not have
permissions to install into /usr/lib64/perl5/site_perl/5.8.8/x86_64-linux at
/usr/lib64/perl5/5.8.8/Foo/Bar.pm> and buried within the install log is an
error saying C<'INSTALL_BASE' is not a known MakeMaker parameter name>, then
you've somehow lost your updated ExtUtils::MakeMaker module.

To remedy this situation, rerun the bootstrapping procedure documented above.

Then, run C<rm -r ~/.cpan/build/Foo-Bar*>

Finally, re-run C<cpan -i Foo::Bar> and it should install without problems.

=head1 ENVIRONMENT

=over 4

=item SHELL

local::lib looks at the user's C<SHELL> environment variable when printing out
commands to add to the shell configuration file.

=back

=head1 AUTHOR

Matt S Trout <mst@shadowcat.co.uk> http://www.shadowcat.co.uk/

auto_install fixes kindly sponsored by http://www.takkle.com/

=head1 CONTRIBUTORS

Patches to correctly output commands for csh style shells, as well as some
documentation additions, contributed by Christopher Nehren <apeiron@cpan.org>.

'--self-contained' feature contributed by Mark Stosberg <mark@summersault.com>.

Doc patches for a custom local::lib directory contributed by Torsten Raudssus
<torsten@raudssus.de>.

Hans Dieter Pearcey <hdp@cpan.org> sent in some additional tests for ensuring
things will install properly, submitted a fix for the bug causing problems with
writing Makefiles during bootstrapping, contributed an example program, and
submitted yet another fix to ensure that local::lib can install and bootstrap
properly. Many, many thanks!

pattern of Freenode IRC contributed the beginnings of the Troubleshooting
section. Many thanks!

=head1 LICENSE

This library is free software under the same license as perl itself

=cut

1;
