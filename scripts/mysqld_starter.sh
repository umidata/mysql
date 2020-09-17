#!@SHELL_PATH@
# Copyright Abandoned 1996 TCX DataKonsult AB & Monty Program KB & Detron HB
# This file is public domain and comes with NO WARRANTY of any kind
#
# Script to start the MySQL daemon and restart it if it dies unexpectedly
#
# This should be executed in the MySQL base directory if you are using a
# binary installation that is not installed in its compile-time default
# location
#
# mysql.server works by first doing a cd to the base directory and from there
# executing mysqld_starter

# Initialize script globals
KILL_MYSQLD=1;
MYSQLD=
niceness=0
mysqld_ld_preload=
mysqld_ld_library_path=
flush_caches=0
numa_interleave=0
numa_nodebind=

# Initial logging status: error log is not open, and not using syslog
logging=init
want_syslog=0
syslog_tag=
user='@MYSQLD_USER@'
pid_file=
err_log=

syslog_tag_mysqld=mysqld
syslog_tag_mysqld_safe=mysqld_safe

exit_code=0

trap '' 1 2 3 15			# we shouldn't let anyone kill us
trap '' 13                              # not even SIGPIPE

# MySQL-specific environment variable. First off, it's not really a umask,
# it's the desired mode. Second, it follows umask(2), not umask(3) in that
# octal needs to be explicit. Our shell might be a proper sh without printf,
# multiple-base arithmetic, and binary arithmetic, so this will get ugly.
# We reject decimal values to keep things at least half-sane.
umask 007                               # fallback
UMASK="${UMASK-0640}"
fmode=`echo "$UMASK" | sed -e 's/[^0246]//g'`
octalp=`echo "$fmode"|cut -c1`
fmlen=`echo "$fmode"|wc -c|sed -e 's/ //g'`
if [ "x$octalp" != "x0" -o "x$UMASK" != "x$fmode" -o "x$fmlen" != "x5" ]
then
  fmode=0640
  echo "UMASK must be a 3-digit mode with an additional leading 0 to indicate octal." >&2
  echo "The first digit will be corrected to 6, the others may be 0, 2, 4, or 6." >&2
fi
fmode=`echo "$fmode"|cut -c3-4`
fmode="6$fmode"
if [ "x$UMASK" != "x0$fmode" ]
then
  echo "UMASK corrected from $UMASK to 0$fmode ..."
fi

defaults=
case "$1" in
    --no-defaults|--defaults-file=*|--defaults-extra-file=*)
      defaults="$1"; shift
      ;;
esac

usage () {
        cat <<EOF
Usage: $0 [OPTIONS]
  --no-defaults              Don't read the system defaults file
  --defaults-file=FILE       Use the specified defaults file
  --defaults-extra-file=FILE Also use defaults from the specified file
  --ledir=DIRECTORY          Look for mysqld in the specified directory
  --open-files-limit=LIMIT   Limit the number of open files
  --core-file-size=LIMIT     Limit core files to the specified size
  --timezone=TZ              Set the system timezone
  --malloc-lib=LIB           Preload shared library LIB if available
  --ld-preload-lib=LIB       Preload shared library LIB
  --mysqld=FILE              Use the specified file as mysqld
  --mysqld-version=VERSION   Use "mysqld-VERSION" as mysqld
  --nice=NICE                Set the scheduling priority of mysqld
  --plugin-dir=DIR           Plugins are under DIR or DIR/VERSION, if
                             VERSION is given
  --skip-kill-mysqld         Don't try to kill stray mysqld processes
  --syslog                   Log messages to syslog with 'logger'
  --skip-syslog              Log messages to error log (default)
  --syslog-tag=TAG           Pass -t "mysqld-TAG" to 'logger'
  --flush-caches             Flush and purge buffers/caches
  --numa-interleave          Run mysqld with its memory interleaved
                             on all CPUs
  --numa-nodebind            Run mysqld with numa binding to one socket

All other options are passed to the mysqld program.

EOF
        exit 1
}

my_which ()
{
  save_ifs="${IFS-UNSET}"
  IFS=:
  ret=0
  for file
  do
    for dir in $PATH
    do
      if [ -f "$dir/$file" ]
      then
        echo "$dir/$file"
        continue 2
      fi
    done

	ret=1  #signal an error
	break
  done

  if [ "$save_ifs" = UNSET ]
  then
    unset IFS
  else
    IFS="$save_ifs"
  fi
  return $ret  # Success
}

log_generic () {
  priority="$1"
  shift

  msg="`date +'%y%m%d %H:%M:%S'` mysqld_safe $*"
  echo "$msg"
  case $logging in
    init) ;;  # Just echo the message, don't save it anywhere
    file)
      if [ -w / -o "$USER" = "root" ]; then
        true
      else
        echo "$msg" >> "$err_log"
      fi
      ;;
    syslog) logger -t "$syslog_tag_mysqld_safe" -p "$priority" "$*" ;;
    *)
      echo "Internal program error (non-fatal):" \
           " unknown logging method '$logging'" >&2
      ;;
  esac
}

log_error () {
  log_generic daemon.error "$@" >&2
}

log_notice () {
  log_generic daemon.notice "$@"
}

eval_log_error () {
  local cmd="$1"
  case $logging in
    file)
      if [ -w / -o "$USER" = "root" ]; then
        cmd="$cmd > /dev/null 2>&1"
      else
        cmd="$cmd >> "`shell_quote_string "$err_log"`" 2>&1"
      fi
      ;;
    syslog)
      # mysqld often prefixes its messages with a timestamp, which is
      # redundant when logging to syslog (which adds its own timestamp)
      # However, we don't strip the timestamp with sed here, because
      # sed buffers output (only GNU sed supports a -u (unbuffered) option)
      # which means that messages may not get sent to syslog until the
      # mysqld process quits.
      #
      # Adding pipefail to return non zero exit code on mysqld failure.
      cmd="set -o pipefail; $cmd 2>&1 | logger -t '$syslog_tag_mysqld' -p daemon.error"
      ;;
    *)
      echo "Internal program error (non-fatal):" \
           " unknown logging method '$logging'" >&2
      ;;
  esac

  #echo "Running mysqld: [$cmd]"
  #set mysqld exit code into $exit_code
  #both stdout/stderr are redirected in $cmd. so
  #exit_code is a return code (not output) of of $cmd
  #which is the same as mysqld's exit code.
  cmd="$cmd; echo \$?"
  exit_code=`eval "$cmd"`
}

shell_quote_string() {
  # This sed command makes sure that any special chars are quoted,
  # so the arg gets passed exactly to the server.
  echo "$1" | sed -e 's,\([^a-zA-Z0-9/_.=-]\),\\\1,g'
}

parse_arguments() {
  # We only need to pass arguments through to the server if we don't
  # handle them here.  So, we collect unrecognized options (passed on
  # the command line) into the args variable.
  pick_args=
  if test "$1" = PICK-ARGS-FROM-ARGV
  then
    pick_args=1
    shift
  fi

  for arg do
    # the parameter after "=", or the whole $arg if no match
    val=`echo "$arg" | sed -e 's;^--[^=]*=;;'`
    # what's before "=", or the whole $arg if no match
    optname=`echo "$arg" | sed -e 's/^\(--[^=]*\)=.*$/\1/'`
    # replace "_" by "-" ; mysqld_safe must accept "_" like mysqld does.
    optname_subst=`echo "$optname" | sed 's/_/-/g'`
    arg=`echo $arg | sed "s/^$optname/$optname_subst/"`
    case "$arg" in
      # these get passed explicitly to mysqld
      --basedir=*) MY_BASEDIR_VERSION="$val" ;;
      --datadir=*) DATADIR="$val" ;;
      --pid-file=*) pid_file="$val" ;;
      --plugin-dir=*) PLUGIN_DIR="$val" ;;
      --user=*) user="$val"; SET_USER=1 ;;

      # these might have been set in a [mysqld_safe] section of my.cnf
      # they are added to mysqld command line to override settings from my.cnf
      --log-error=*) err_log="$val" ;;
      --port=*) mysql_tcp_port="$val" ;;
      --socket=*) mysql_unix_port="$val" ;;

      # mysqld_safe-specific options - must be set in my.cnf ([mysqld_safe])!
      --core-file-size=*) core_file_size="$val" ;;
      --ledir=*)
        if [ -z "$pick_args" ]; then
          log_error "--ledir option can only be used as command line option, found in config file"
          exit 1
        fi
        ledir="$val"
        ;;
      --malloc-lib=*) set_malloc_lib "$val" ;;
      --ld-preload-lib=*)
        if [ -z "$pick_args" ]; then
          log_error "--ld-preload-lib option can only be used as command line option, found in config file"
          exit 1
        fi
        add_mysqld_ld_preload "$val" ;;
      --mysqld=*)
        if [ -z "$pick_args" ]; then
          log_error "--mysqld option can only be used as command line option, found in config file"
          exit 1
        fi
        MYSQLD="$val" ;;
      --mysqld-version=*)
        if [ -z "$pick_args" ]; then
          log_error "--mysqld-version option can only be used as command line option, found in config file"
          exit 1
        fi
        if test -n "$val"
        then
          MYSQLD="mysqld-$val"
          PLUGIN_VARIANT="/$val"
        else
          MYSQLD="mysqld"
        fi
        ;;
      --nice=*) niceness="$val" ;;
      --open-files-limit=*) open_files="$val" ;;
      --open_files_limit=*) open_files="$val" ;;
      --skip-kill-mysqld*) KILL_MYSQLD=0 ;;
      --syslog) want_syslog=1 ;;
      --skip-syslog) want_syslog=0 ;;
      --syslog-tag=*) syslog_tag="$val" ;;
      --timezone=*) TZ="$val"; export TZ; ;;
      --flush-caches) flush_caches=1 ;;
      --numa-interleave) numa_interleave=1 ;;
      --numa-nodebind=*) numa_nodebind="$val" ;;

      --help) usage ;;

      *)
        if test -n "$pick_args"
        then
          append_arg_to_args "$arg"
        fi
        ;;
    esac
  done
}


# Add a single shared library to the list of libraries which will be added to
# LD_PRELOAD for mysqld
#
# Since LD_PRELOAD is a space-separated value (for historical reasons), if a
# shared lib's path contains spaces, that path will be prepended to
# LD_LIBRARY_PATH and stripped from the lib value.
add_mysqld_ld_preload() {
  lib_to_add="$1"
  log_notice "Adding '$lib_to_add' to LD_PRELOAD for mysqld"

  case "$lib_to_add" in
    *' '*)
      # Must strip path from lib, and add it to LD_LIBRARY_PATH
      lib_file=`basename "$lib_to_add"`
      case "$lib_file" in
        *' '*)
          # The lib file itself has a space in its name, and can't
          # be used in LD_PRELOAD
          log_error "library name '$lib_to_add' contains spaces and can not be used with LD_PRELOAD"
          exit 1
          ;;
      esac
      lib_path=`dirname "$lib_to_add"`
      lib_to_add="$lib_file"
      [ -n "$mysqld_ld_library_path" ] && mysqld_ld_library_path="$mysqld_ld_library_path:"
      mysqld_ld_library_path="$mysqld_ld_library_path$lib_path"
      ;;
  esac

  # Do not add if file does not exist.
  if [ ! -f  "$lib_to_add" ]; then
    log_error "no shared library found for $lib_to_add"
    return
  fi

  # LD_PRELOAD is a space-separated
  [ -n "$mysqld_ld_preload" ] && mysqld_ld_preload="$mysqld_ld_preload "
  mysqld_ld_preload="${mysqld_ld_preload}$lib_to_add"
}


# Returns LD_PRELOAD (and LD_LIBRARY_PATH, if needed) text, quoted to be
# suitable for use in the eval that calls mysqld.
#
# All values in mysqld_ld_preload are prepended to LD_PRELOAD.
mysqld_ld_preload_text() {
  text=

  if [ -n "$mysqld_ld_preload" ]; then
    new_text="$mysqld_ld_preload"
    [ -n "$LD_PRELOAD" ] && new_text="$new_text $LD_PRELOAD"
    text="${text}LD_PRELOAD="`shell_quote_string "$new_text"`' '
  fi

  if [ -n "$mysqld_ld_library_path" ]; then
    new_text="$mysqld_ld_library_path"
    [ -n "$LD_LIBRARY_PATH" ] && new_text="$new_text:$LD_LIBRARY_PATH"
    text="${text}LD_LIBRARY_PATH="`shell_quote_string "$new_text"`' '
  fi

  echo "$text"
}

# set_malloc_lib LIB
# - If LIB is empty, do nothing and return
# - If LIB is 'tcmalloc', look for tcmalloc shared library in $malloc_dirs.
#   tcmalloc is part of the Google perftools project.
# - If LIB is an absolute path, assume it is a malloc shared library
#
# Put LIB in mysqld_ld_preload, which will be added to LD_PRELOAD when
# running mysqld.  See ld.so for details.
set_malloc_lib() {
  # This list is kept intentionally simple.
  malloc_dirs="/usr/lib /usr/lib64 /usr/lib/i386-linux-gnu /usr/lib/x86_64-linux-gnu"
  malloc_lib="$1"

  if [ "$malloc_lib" = tcmalloc ]; then
    malloc_lib=
    for libdir in `echo $malloc_dirs`; do
      for flavor in _minimal '' _and_profiler _debug; do
        tmp="$libdir/libtcmalloc$flavor.so"
        #log_notice "DEBUG: Checking for malloc lib '$tmp'"
        [ -r "$tmp" ] || continue
        malloc_lib="$tmp"
        break 2
      done
    done

    if [ -z "$malloc_lib" ]; then
      log_error "no shared library for --malloc-lib=tcmalloc found in $malloc_dirs"
      exit 1
    fi
  fi

  # Allow --malloc-lib='' to override other settings
  [ -z  "$malloc_lib" ] && return

  case "$malloc_lib" in
    /*)
      if [ ! -r "$malloc_lib" ]; then
        log_error "--malloc-lib can not be read and will not be used"
        exit 1
      fi

      # Restrict to a the list in $malloc_dirs above
      case "`dirname "$malloc_lib"`" in
        /usr/lib) ;;
        /usr/lib64) ;;
        /usr/lib/i386-linux-gnu) ;;
        /usr/lib/x86_64-linux-gnu) ;;
        *)
          log_error "--malloc-lib must be located in one of the directories: $malloc_dirs"
          exit 1
          ;;
      esac
      ;;
    *)
      log_error "--malloc-lib must be an absolute path or 'tcmalloc'; " \
        "ignoring value '$malloc_lib'"
      exit 1
      ;;
  esac

  add_mysqld_ld_preload "$malloc_lib"
}


#
# First, try to find BASEDIR and ledir (where mysqld is)
#

if echo '@pkgdatadir@' | grep '^@prefix@' > /dev/null
then
  relpkgdata=`echo '@pkgdatadir@' | sed -e 's,^@prefix@,,' -e 's,^/,,' -e 's,^,./,'`
else
  # pkgdatadir is not relative to prefix
  relpkgdata='@pkgdatadir@'
fi

case "$0" in
  /*)
  MY_PWD='@prefix@'
  ;;
  *)
  MY_PWD=`dirname $0`
  MY_PWD=`dirname $MY_PWD`
  ;;
esac
# Check for the directories we would expect from a binary release install
if test -n "$MY_BASEDIR_VERSION" -a -d "$MY_BASEDIR_VERSION"
then
  # BASEDIR is already overridden on command line.  Do not re-set.

  # Use BASEDIR to discover le.
  if test -x "$MY_BASEDIR_VERSION/libexec/mysqld"
  then
    ledir="$MY_BASEDIR_VERSION/libexec"
  elif test -x "$MY_BASEDIR_VERSION/sbin/mysqld"
  then
    ledir="$MY_BASEDIR_VERSION/sbin"
  else
    ledir="$MY_BASEDIR_VERSION/bin"
  fi
elif test -f "$relpkgdata"/english/errmsg.sys -a -x "$MY_PWD/bin/mysqld"
then
  MY_BASEDIR_VERSION="$MY_PWD"		# Where bin, share and data are
  ledir="$MY_PWD/bin"			# Where mysqld is
# Check for the directories we would expect from a source install
elif test -f "$relpkgdata"/english/errmsg.sys -a -x "$MY_PWD/libexec/mysqld"
then
  MY_BASEDIR_VERSION="$MY_PWD"		# Where libexec, share and var are
  ledir="$MY_PWD/libexec"		# Where mysqld is
elif test -f "$relpkgdata"/english/errmsg.sys -a -x "$MY_PWD/sbin/mysqld"
then
  MY_BASEDIR_VERSION="$MY_PWD"		# Where sbin, share and var are
  ledir="$MY_PWD/sbin"			# Where mysqld is
# Since we didn't find anything, used the compiled-in defaults
else
  MY_BASEDIR_VERSION='@prefix@'
  ledir='@libexecdir@'
fi


#
# Second, try to find the data directory
#

# Try where the binary installs put it
if test -d $MY_BASEDIR_VERSION/data/mysql
then
  DATADIR=$MY_BASEDIR_VERSION/data
  if test -z "$defaults" -a -r "$DATADIR/my.cnf"
  then
    defaults="--defaults-extra-file=$DATADIR/my.cnf"
  fi
# Next try where the source installs put it
elif test -d $MY_BASEDIR_VERSION/var/mysql
then
  DATADIR=$MY_BASEDIR_VERSION/var
# Or just give up and use our compiled-in default
else
  DATADIR=@localstatedir@
fi

if test -z "$MYSQL_HOME"
then 
  if test -r "$MY_BASEDIR_VERSION/my.cnf" && test -r "$DATADIR/my.cnf"
  then
    log_error "WARNING: Found two instances of my.cnf -
$MY_BASEDIR_VERSION/my.cnf and
$DATADIR/my.cnf
IGNORING $DATADIR/my.cnf"

    MYSQL_HOME=$MY_BASEDIR_VERSION
  elif test -r "$DATADIR/my.cnf"
  then
    log_error "WARNING: Found $DATADIR/my.cnf
The data directory is a deprecated location for my.cnf, please move it to
$MY_BASEDIR_VERSION/my.cnf"
    MYSQL_HOME=$DATADIR
  else
    MYSQL_HOME=$MY_BASEDIR_VERSION
  fi
fi
export MYSQL_HOME


# Get first arguments from the my.cnf file, groups [mysqld] and [mysqld_safe]
# and then merge with the command line arguments
if test -x "$MY_BASEDIR_VERSION/bin/my_print_defaults"
then
  print_defaults="$MY_BASEDIR_VERSION/bin/my_print_defaults"
elif test -x `dirname $0`/my_print_defaults
then
  print_defaults="`dirname $0`/my_print_defaults"
elif test -x ./bin/my_print_defaults
then
  print_defaults="./bin/my_print_defaults"
elif test -x @bindir@/my_print_defaults
then
  print_defaults="@bindir@/my_print_defaults"
elif test -x @bindir@/mysql_print_defaults
then
  print_defaults="@bindir@/mysql_print_defaults"
else
  print_defaults="my_print_defaults"
fi

append_arg_to_args () {
  args="$args "`shell_quote_string "$1"`
}

args=

SET_USER=2
parse_arguments `$print_defaults $defaults --loose-verbose mysqld server`
if test $SET_USER -eq 2
then
  SET_USER=0
fi

parse_arguments `$print_defaults $defaults --loose-verbose mysqld_safe safe_mysqld`
parse_arguments PICK-ARGS-FROM-ARGV "$@"

#
# Try to find the plugin directory
#

# Use user-supplied argument
if [ -n "${PLUGIN_DIR}" ]; then
  plugin_dir="${PLUGIN_DIR}"
else
  # Try to find plugin dir relative to basedir
  for dir in lib64/mysql/plugin lib64/plugin lib/mysql/plugin lib/plugin
  do
    if [ -d "${MY_BASEDIR_VERSION}/${dir}" ]; then
      plugin_dir="${MY_BASEDIR_VERSION}/${dir}"
      break
    fi
  done
  # Give up and use compiled-in default
  if [ -z "${plugin_dir}" ]; then
    plugin_dir='@pkgplugindir@'
  fi
fi
plugin_dir="${plugin_dir}${PLUGIN_VARIANT}"

# Determine what logging facility to use

# Ensure that 'logger' exists, if it's requested
if [ $want_syslog -eq 1 ]
then
  my_which logger > /dev/null 2>&1
  if [ $? -ne 0 ]
  then
    log_error "--syslog requested, but no 'logger' program found.  Please ensure that 'logger' is in your PATH, or do not specify the --syslog option to mysqld_safe."
    exit 1
  fi
fi

if [ -n "$err_log" -o $want_syslog -eq 0 ]
then
  if [ -n "$err_log" ]
  then
    # mysqld adds ".err" if there is no extension on the --log-error
    # argument; must match that here, or mysqld_safe will write to a
    # different log file than mysqld

    # mysqld does not add ".err" to "--log-error=foo."; it considers a
    # trailing "." as an extension
    
    if expr "$err_log" : '.*\.[^/]*$' > /dev/null
    then
        :
    else
      err_log="$err_log".err
    fi

    case "$err_log" in
      /* ) ;;
      * ) err_log="$DATADIR/$err_log" ;;
    esac
  else
    err_log=$DATADIR/`@HOSTNAME@`.err
  fi

  append_arg_to_args "--log-error=$err_log"

  if [ $want_syslog -eq 1 ]
  then
    # User explicitly asked for syslog, so warn that it isn't used
    log_error "Can't log to error log and syslog at the same time.  Remove all --log-error configuration options for --syslog to take effect."
  fi

  # Log to err_log file
  logging=file
else
  if [ -n "$syslog_tag" ]
  then
    # Sanitize the syslog tag
    syslog_tag=`echo "$syslog_tag" | sed -e 's/[^a-zA-Z0-9_-]/_/g'`
    syslog_tag_mysqld_safe="${syslog_tag_mysqld_safe}-$syslog_tag"
    syslog_tag_mysqld="${syslog_tag_mysqld}-$syslog_tag"
  fi
  log_notice "Logging to syslog."
  logging=syslog
fi

logdir=`dirname "$err_log"`
# Change the err log to the right user, if possible and it is in use
if [ $logging = "file" -o $logging = "both" ]; then
  if [ ! -f "$err_log" -a ! -h "$err_log" ]; then
    if test -w / -o "$USER" = "root"; then
      case $logdir in
        /var/log)
          (
            umask 0137
            set -o noclobber
            > "$err_log" && chown $user "$err_log"
          ) ;;
        *) ;;
      esac
    else
      (
        umask 0137
        set -o noclobber
        > "$err_log"
      )
    fi
  fi

  if [ -f "$err_log" ]; then        # Log to err_log file
    log_notice "Logging to '$err_log'."
  elif [ "x$user" = "xroot" ]; then # running as root, mysqld can create log file; continue
    echo "Logging to '$err_log'." >&2
  else
    case $logdir in
      # We can't create $err_log, however mysqld can; continue
      /tmp|/var/tmp|/var/log/mysql|$DATADIR)
        echo "Logging to '$err_log'." >&2
        ;;
      # We can't create $err_log and don't know if mysqld can; error out
      *)
        log_error "error: log-error set to '$err_log', however file don't exists. Create writable for user '$user'."
        exit 1
        ;;
    esac
  fi
fi

USER_OPTION=""
if test -w / -o "$USER" = "root"
then
  if test "$user" != "root" -o $SET_USER = 1
  then
    USER_OPTION="--user=$user"
  fi
  if test -n "$open_files"
  then
    ulimit -n $open_files
  fi
fi

if test -n "$open_files"
then
  append_arg_to_args "--open-files-limit=$open_files"
fi

safe_mysql_unix_port=${mysql_unix_port:-${MYSQL_UNIX_PORT:-@MYSQL_UNIX_ADDR@}}
# Check that directory for $safe_mysql_unix_port exists
mysql_unix_port_dir=`dirname $safe_mysql_unix_port`
if [ ! -d $mysql_unix_port_dir ]
then
  log_error "Directory '$mysql_unix_port_dir' for UNIX socket file don't exists."
  exit 1
fi

# If the user doesn't specify a binary, we assume name "mysqld"
if test -z "$MYSQLD"
then
  MYSQLD=mysqld
fi

if test ! -x "$ledir/$MYSQLD"
then
  log_error "The file $ledir/$MYSQLD
does not exist or is not executable. Please cd to the mysql installation
directory and restart this script from there as follows:
./bin/mysqld_starter&
See http://dev.mysql.com/doc/mysql/en/mysqld-safe.html for more information"
  exit 1
fi
setcap 'cap_sys_nice=eip' $ledir/$MYSQLD
if [ $? -ne 0 ]
then
  echo "Failed to set capabilities"
fi

if test -z "$pid_file"
then
  pid_file="$DATADIR/`@HOSTNAME@`.pid"
else
  case "$pid_file" in
    /* ) ;;
    * )  pid_file="$DATADIR/$pid_file" ;;
  esac
fi
append_arg_to_args "--pid-file=$pid_file"

if test -n "$mysql_unix_port"
then
  append_arg_to_args "--socket=$mysql_unix_port"
fi
if test -n "$mysql_tcp_port"
then
  append_arg_to_args "--port=$mysql_tcp_port"
fi

if test $niceness -eq 0
then
  NOHUP_NICENESS="nohup"
else
  NOHUP_NICENESS="nohup nice -$niceness"
fi

# Using nice with no args to get the niceness level is GNU-specific.
# This check could be extended for other operating systems (e.g.,
# BSD could use "nohup sh -c 'ps -o nice -p $$' | tail -1").
# But, it also seems that GNU nohup is the only one which messes
# with the priority, so this is okay.
if nohup nice > /dev/null 2>&1
then
    normal_niceness=`nice`
    nohup_niceness=`nohup nice 2>/dev/null`

    numeric_nice_values=1
    for val in $normal_niceness $nohup_niceness
    do
        case "$val" in
            -[0-9] | -[0-9][0-9] | -[0-9][0-9][0-9] | \
             [0-9] |  [0-9][0-9] |  [0-9][0-9][0-9] )
                ;;
            * )
                numeric_nice_values=0 ;;
        esac
    done

    if test $numeric_nice_values -eq 1
    then
        nice_value_diff=`expr $nohup_niceness - $normal_niceness`
        if test $? -eq 0 && test $nice_value_diff -gt 0 && \
            nice --$nice_value_diff echo testing > /dev/null 2>&1
        then
            # nohup increases the priority (bad), and we are permitted
            # to lower the priority with respect to the value the user
            # might have been given
            niceness=`expr $niceness - $nice_value_diff`
            NOHUP_NICENESS="nice -$niceness nohup"
        fi
    fi
else
    if nohup echo testing > /dev/null 2>&1
    then
        :
    else
        # nohup doesn't work on this system
        NOHUP_NICENESS=""
    fi
fi

# Try to set the core file size (even if we aren't root) because many systems
# don't specify a hard limit on core file size.
if test -n "$core_file_size"
then
  ulimit -c $core_file_size
fi

#
# If there exists an old pid file, check if the daemon is already running
# Note: The switches to 'ps' may depend on your operating system
if test -f "$pid_file"
then
  PID=`cat "$pid_file"`
  if @CHECK_PID@
  then
    if @FIND_PROC@
    then    # The pid contains a mysqld process
      log_error "A mysqld process already exists"
      exit 1
    fi
  fi
  if [ ! -h "$pid_file" ]; then
      rm -f "$pid_file"
  fi
  if test -f "$pid_file"
  then
    log_error "Fatal error: Can't remove the pid file:
$pid_file
Please remove it manually and start $0 again;
mysqld daemon not started"
    exit 1
  fi
fi

#
# Flush and purge buffers/caches.
#

if @TARGET_LINUX@ && test $flush_caches -eq 1
then
  # Locate sync, ensure it exists.
  if ! my_which sync > /dev/null 2>&1
  then
    log_error "sync command not found, required for --flush-caches"
    exit 1
  # Flush file system buffers.
  elif ! sync
  then
    # Huh, the sync() function is always successful...
    log_error "sync failed, check if sync is properly installed"
  fi

  # Locate sysctl, ensure it exists.
  if ! my_which sysctl > /dev/null 2>&1
  then
    log_error "sysctl command not found, required for --flush-caches"
    exit 1
  # Purge page cache, dentries and inodes.
  elif ! sysctl -q -w vm.drop_caches=3
  then
    log_error "sysctl failed, check the error message for details"
    exit 1
  fi
elif test $flush_caches -eq 1
then
  log_error "--flush-caches is not supported on this platform"
  exit 1
fi

#
# Uncomment the following lines if you want all tables to be automatically
# checked and repaired during startup. You should add sensible key_buffer
# and sort_buffer values to my.cnf to improve check performance or require
# less disk space.
# Alternatively, you can start mysqld with the "myisam-recover" option. See
# the manual for details.
#
# echo "Checking tables in $DATADIR"
# $MY_BASEDIR_VERSION/bin/myisamchk --silent --force --fast --medium-check $DATADIR/*/*.MYI
# $MY_BASEDIR_VERSION/bin/isamchk --silent --force $DATADIR/*/*.ISM

# Does this work on all systems?
#if type ulimit | grep "shell builtin" > /dev/null
#then
#  ulimit -n 256 > /dev/null 2>&1		# Fix for BSD and FreeBSD systems
#fi

cmd="$NOHUP_NICENESS"

#
# Set mysqld's memory interleave policy.
#

if @TARGET_LINUX@ && test $numa_interleave -eq 1
then
  # Locate numactl, ensure it exists.
  if ! my_which numactl > /dev/null 2>&1
  then
    log_error "numactl command not found, required for --numa-interleave"
    exit 1
  # Attempt to run a command, ensure it works.
  elif ! numactl --interleave=all true
  then
    log_error "numactl failed, check if numactl is properly installed"
  fi

  # Launch mysqld with numactl.
  cmd="$cmd numactl --interleave=all"
elif test $numa_interleave -eq 1
then
  log_error "--numa-interleave is not supported on this platform"
  exit 1
fi

if @TARGET_LINUX@ && test ! -z "$numa_nodebind"
then
  # Locate numactl, ensure it exists.
  if ! my_which numactl > /dev/null 2>&1
  then
    log_error "numactl command not found, required for --numa-nodebind"
    exit 1
  fi

  # Attempt to run a command, ensure it works.
  if ! numactl --cpunodebind=$numa_nodebind --preferred=$numa_nodebind true
  then
    log_error "numactl failed, check if numa-nodebind value is correct"
    exit 1
  fi

  # Launch mysqld with numactl.
  cmd="$cmd numactl --cpunodebind=$numa_nodebind --preferred=$numa_nodebind"
elif test ! -z "$numa_nodebind"
then
  log_error "--numa-nodebind is not supported on this platform"
  exit 1
fi

if [ ! -z "`mysqld_ld_preload_text`" ]; then
  cmd="$cmd env `mysqld_ld_preload_text`"
fi

for i in  "$ledir/$MYSQLD" "$defaults" "--basedir=$MY_BASEDIR_VERSION" \
  "--datadir=$DATADIR" "--plugin-dir=$plugin_dir" "$USER_OPTION"
do
  cmd="$cmd "`shell_quote_string "$i"`
done
cmd="$cmd $args"
cmd_skip_core="$cmd --skip-core-file"
# Avoid 'nohup: ignoring input' warning
test -n "$NOHUP_NICENESS" && cmd="$cmd < /dev/null" \
                          && cmd_skip_core="$cmd_skip_core < /dev/null"
cmd_saved="$cmd"

log_notice "Starting $MYSQLD daemon with databases from $DATADIR"

# Some extra safety
if [ ! -h "$safe_mysql_unix_port" ]; then
  rm -f "$safe_mysql_unix_port"
fi
if [ ! -h "$pid_file" ]; then
  rm -f "$pid_file"
fi
if [ ! -h "$pid_file.shutdown" ]; then
  rm -f "$pid_file.shutdown"
fi

eval_log_error "$cmd"

# hypothetical: log was renamed but not
# flushed yet. we'd recreate it with
# wrong owner next time we log, so set
# it up correctly while we can!

if [ $want_syslog -eq 0 -a ! -f "$err_log" -a ! -h "$err_log" ]; then
  if test -w / -o "$USER" = "root"; then
    logdir=`dirname "$err_log"`
    case $logdir in
      /var/log)
        (
          umask 0137
          set -o noclobber
          > "$err_log" && chown $user "$err_log"
        ) ;;
      *) ;;
    esac
  else
    (
      umask 0137
      set -o noclobber
      > "$err_log"
    )
  fi
fi

log_notice "mysqld from pid file $pid_file ended"

exit $exit_code
