#!/usr/bin/perl -w
#2345678911234567892123456789312345678941234567895123456789612345678971234567898
use Data::Dumper;
$Data::Dumper::Sortkeys = 1;

# Regenerate (overwriting only if changed):

#    lock_definitions.h

# Also accepts the standard regen_lib -q and -v args.

# This script is normally invoked from regen.pl.

BEGIN {
    require './regen/regen_lib.pl';
}

use strict;
use warnings;
#use feature 'signatures';

my $generic_lock = 'env';
my $MAX_LINE_WIDTH = 79;
my $comment_columns = $MAX_LINE_WIDTH - 3;  # For "/* " on first line; " * "
                                            # on subsequent ones

my @categories;
my %functions;
my %race_tags;

my @unsuitables;
my @need_single_thread_init;
my @signal_issues;

sub open_print_header {
    my ($file, $quote) = @_;
    return open_new($file, '>',
                    { by => 'regen/lock_definitions.pl',
                      from => 'data in regen/lock_definitions.pl',
                      file => $file, style => '*',
                      copyright => [2023..2024],
                      quote => $quote });
}

my $l = open_print_header('lock_definitions.h');
print $l <<EOF;
EOF

sub name_order {    # sort helper
    lc $a =~ s/  _+ //xr cmp lc $b =~ s/  _+ //xr;
}

my @DATA = <DATA>;
close DATA;

while (defined ($_ = shift @DATA)) {
    chomp;
    next if /^\s*$/;
    next if m:^\s*//:;
    last if /^__END__/;

    if (/^#/) {
        next;
    }
        
    my ($functions, $restrictions, $dummy) = split /\s*\|\s*/, $_;
    croak("Extra '|' in input '$_'") if defined $dummy;

    while ($functions =~ / , \s* $/x) {
        $functions .= shift @DATA;
    }
    chomp $functions;
    print STDERR __FILE__, ": ", __LINE__, ": ", $functions, "\n";
    print STDERR __FILE__, ": ", __LINE__, ": ", $restrictions, "\n";

    my @categories;
    my @races;
    my @conditions;
    my @signals;
    my @notes;
    my @need_consts;
    my %locks;
    my $unsuitable;
    my $timer = 0;
    my $need_init = 0;

    while ($restrictions =~ /\S/) {
        $restrictions =~ s/^\s+//;
        $restrictions =~ s/\s+$//;

        if ($restrictions =~ s/ ^ U $ //x) {
            $unsuitable = "";
            next;
        }

        if ($restrictions =~ s/ ^ const: ( \S+ ) //x) {
            $unsuitable = "CONST";
            next;
        }

        if ($restrictions =~ s! ^ R ( .*? ) (?: / ( \S* ) )? \b !!x) {
            my $race = $1;
            my $condition = $2;
            if ($condition) {
                push @conditions, $condition;
            }
            else {
                push @races, $race;
            }
            next;
        }

        if ($restrictions =~ s/ ^ ( LC_\S+ ) //x) {
            push @categories, $1;
            next;
        }

        if ($restrictions =~ s/ ^ sig: ( \S+ ) //x) {
            push @signals, $1;
            next;
        }

        if ($restrictions =~ s/ ^ ( init ) \b //x) {
            $need_init = 1;
            next;
        }

        if ($restrictions =~ s/ ^ ( timer ) \b //x) {
            $timer = 1;
            next;
        }

        if (   $restrictions =~ s/ ^ ( [EL] ) ( [[:lower:]]+ ) \b //x
            or $restrictions =~ s/ ^ ( term | cwd ) \b //x)
        {
            my $lock = $1;
            my $lock_type = $2;

            #print STDERR __FILE__, ": ", __LINE__, ": $1: $2\n";
            if ($lock eq 'L') {
                $lock = 'locale';
            }
            elsif ($lock eq 'E') {
                $lock = 'env';
            }
            else {
                $lock = $generic_lock;
            }

            croak("Already has locale lock") if exists $locks{$lock};

            $lock_type = 'w' unless defined $lock_type;
            $locks{$lock} = $lock_type;
            next;
        }

        if ($restrictions =~ s/ ^ (hostid | sigintr ) \b //x) {
            push @need_consts, $1;
            next;
        }

        if ($restrictions =~ s/ ^ N \s+ ( .* ) $ //x) {
            push @notes, "$1";
            last;
        }

        last if $restrictions =~ s/ ^ # \s$ .* $ //x;

        croak("Unexpected input '$_'") if $restrictions =~ /\S/;
    }

    # The Linux man pages include this keyword with no explanation.  khw
    # thinks it is obsolete because it always seems associated with SIGALRM.
    # But add this check to be sure.
    croak ("'timer' keyword not associated with signal ALRM")
                                if $timer && ! grep { $_ eq 'ALRM' } @signals;

    foreach my $function (split /\s*,\s*/, $functions) {
        croak("Illegal function syntax: '$function'") if $function =~ /\W/;
        croak("$function already has an entry") if exists $functions{$function};

        push $functions{$function}{categories}->@*, @categories if @categories;
        push $functions{$function}{races}->@*, @races if @races;
        push $functions{$function}{conditions}->@*, @conditions if @conditions;
        if (@signals) {
            push $functions{$function}{signals}->@*, @signals;
            push @signal_issues, $function;
        }
        push $functions{$function}{need_consts}->@*, @need_consts if @need_consts;
        if ($need_init) {
            push @notes, "must be called at least once in single-threaded mode"
                       . " to enable any semblance of thread-safety in"
                       . " subsequent calls.";
            push @need_single_thread_init, $function;
        }
        push $functions{$function}{notes}->@*, @notes if @notes;
        $functions{$function}{locks}->%* = %locks if %locks;
        if (defined $unsuitable) {
            $functions{$function}{unsuitable} = 1;
            push @unsuitables, $function;
        }

        if (@races > 1 || (@races && $races[0] ne "")) {
            $race_tags{$_}{$function} = 1 for @races;
        }

        $functions{$function}{noop} = 1 unless defined $functions{$function};
    }
}

print $l <<EOT;
/* This file contains macros to wrap their respective function calls to ensure
 * that those calls are thread-safe in a multi-threaded environment.
 * 
 * Most libc functions are already thread-safe without these wrappers, so do
 * not appear here.  The functions that are known to have multi-thread issues
 * are:
 *
EOT

my $text = columnarize_list( [ sort name_order keys %functions ],
                            $comment_columns);
$text =~ s/^/ * /gm;
print $l $text;

if (@unsuitables) {
    print $l <<EOT;
 *
 * If a function doesn't appear in the above list, perl thinks it is
 * thread-safe on all platforms.  If your experience is otherwise, add an
 * entry in the DATA portion of this file.
 *
 * A few calls are considered totally unsuited for use in a multi-thread
 * environment.  No wrapper macros are generated for these, which must be
 * called only during single-thread operation:
 *
EOT
    $text = columnarize_list( [ sort name_order @unsuitables],
                                $comment_columns);
    $text =~ s/^/ * /gm;
    print $l $text;
}

if (@need_single_thread_init) {
    print $l <<EOT;
 *
 * Some functions perform initialization on their first call that must be done
 * while still in a single-thread environment, but subsequent calls are
 * thread-safe when wrapped with the respective macros defined in this file.
 * Therefore, they must be called at least once before switching to
 * multi-threads:
 *
EOT

    $text = columnarize_list( [ sort name_order @need_single_thread_init],
                                $comment_columns);
    $text =~ s/^/ * /gm;
    print $l $text;
}

print $l <<EOT;
 *
 * Some functions use and/or modify a global state, such as a database.
 * The libc functions presume that there is only one thread at a time
 * operating on that database.  Unpredictable results occur if more than one
 * does, even if the database is not changed.  For example, typically there is
 * a global iterator for the data base maintained by libc, so that each new
 * read from any thread advances it, meaning that no thread will see all the
 * entries.  The only way to make these thread-safe is to have an exclusive
 * lock on a mutex from the open call to the close.  This is beyond the
 * current scope of this header.  You are advised to not use such databases
 * from more than one thread at a time.  The lock macros here only are
 * designed to make the individual function calls thread-safe just for the
 * duration of the call.  Comments at each definition tell what other
 * functions have races with that function.  Typically the functions that fall
 * into this class have races with other functions whose names begin with
 * "end", such as "endgrent()".
 *
 * Other functions that output to a stream also are considered thread-unsafe
 * without locking.  but the typical consequences are just that the data is
 * output in unpredicatble ways, which may be totally acceptable.
 *
 * The rest of the functions, when wrapped with their respective LOCK and
 * UNLOCK macros, should be thread-safe.
 *
 * However, ome of these are not thread-safe if called with arguments that
 * don't comply with certain (easily-met) restrictions.  Those are commented
 * where their respective macros are #defined.
EOT

if (@signal_issues) {
    print $l <<EOT;
 *
 * The macros here do not help in coping with asynchronous signals.  For
 * these, you need to see the vendor man pages.  The functions here known to
 * be vulnerable to signals are:
 *
EOT
    $text = columnarize_list( [ sort name_order @signal_issues ],
                                $comment_columns);
    $text =~ s/^/ * /gm;
    print $l $text;
}

print $l <<EOT;
 *
 * The macros here all should expand to no-ops when run from an unthreaded
 * perl.  Many also expand to no-ops on various other platforms and
 * Configurations.  They exist so you you don't have to worry about this.
 *
 * The macros are designed to not result in deadlock, except deadlock WILL
 * occur if they are used in such a way that a thread tries to acquire a
 * write-lock on a mutex when it already holds a read-lock on that mutex.
 * This could be handled transparently (with significant extra overhead), but
 * applications don't tend to be written in such a way that this issue even
 * comes up.  Best practice is to call the LOCK macro; call the function and
 * copy the result to a per-thread place if that result points to a buffer
 * internal to libc; then UNLOCK it immediately.
 *
 * The macros here are generated from an internal DATA section, populated from
 * information derived from the POSIX 2017 standard and Linux glibc section 3
 * man pages.  (Linux tends to have extra restrictions not in the Standard.)
 * The data can easily be adjusted as necessary.
 *
 * But beware that the Standard contains weasel words that could make
 * multi-thread safety a fiction, depending on the application.  .  Our
 * experience though is * that libc implementations don't take advantage of this
 * loophole, and the * macros here are written as if it didn't exist.  (See
 * https://stackoverflow.com/questions/78056645 )* The POSIX standard also says
 *
 *    A thread-safe function can be safely invoked concurrently with other
 *    calls to the same function, or with calls to any other thread-safe
 *    functions, by multiple threads. Each function defined in the System
 *    Interfaces volume of POSIX.1-2017 is thread-safe unless explicitly stated
 *    otherwise. Examples are any 'pure' function, a function which holds a
 *    mutex locked while it is accessing static storage or objects shared
 *    among threads.
 *
 * Note that this doesn't say anything about the behavior of a thread-safe
 * function when executing concurrently with a thread-unsafe function.  This
 * effectively gives permission for a libc implementation to make every
 * allegedly thread-safe function not thread-safe for circumstances outside the
 * control of the thread.  This would wreak havoc on a lot of code if
 * libc implementations took much advantage of this loophole.  But it is a
 * reason to avoid creating many mutexes.  Two threads are always thread-safe
 * if they lock on the same mutex.
 *
 * Another reason to minimize the number of mutexes is that each additional one
 * increases the possibility of deadklock, unless the code is (and remains
 * so during future maintenance) carefully crafted.
 *
 * There are other libc functions that reasonably could have their own mutex.
 * But for the above two reasons, and the expectation that these aren't used
 * all that often, that isn't currently done.  All of them share the locale
 * mutex.  For example, two concurrent threads executing ttyname() can have
 * races.  If benchmarks showed that creating a mutex for just this case sped
 * things up, we'd have to consider that.  Another example is getservent(),
 * setservent(), and endservent() could share their own mutex.  Again that
 * isn't currently done; they are all lumped to using the locale mutex.
 */
EOT

#print STDERR __FILE__, ": ", __LINE__, ": ", Dumper \%functions, \%race_tags;
foreach my $function (sort name_order keys %functions) {
    my @comments;
    my $need_exclusive = 0;

    my $output_function_name = "$function() ";
    my $hanging = " " x length $output_function_name;

    my $this_data = $functions{$function};
    print STDERR __FILE__, ": ", __LINE__, ": ", Dumper $function, $this_data;
    if ($this_data->{unsuitable}) {
        my $text = "${output_function_name}is unsuitable for a multi-threaded"
                 . " environment.";
        push @comments, split "\n", wrap($comment_columns, "", $hanging, $text);
    }

    if ($this_data->{notes}) {
        foreach my $note ($this_data->{notes}->@*) {
            push @comments, split "\n", wrap($comment_columns, "", $hanging,
                                             $output_function_name . $note);
        }
    }
                                                
    if ($this_data->{signals}) {
        my $signal_count = $this_data->{signals}->@*;
        my $text = "${output_function_name}is vulnerable to signal";
        $text .= "s" if $signal_count > 1;
        $text .= " " . join(", ", $this_data->{signals}->@*);
        push @comments, split "\n", wrap($comment_columns, "", $hanging, $text);
    }

    if ($this_data->{races}) {
        my %races_with;
        #print STDERR __FILE__, ": ", __LINE__, ": ", Dumper $this_data->{races};
        foreach my $tag ($this_data->{races}->@*) {
            #print STDERR __FILE__, ": ", __LINE__, ": ", Dumper $tag, $race_tags{$tag};
            $races_with{$_} = 1 for keys $race_tags{$tag}->%*;
        }
        #print STDERR __FILE__, ": ", __LINE__, ": ", Dumper \%races_with;

        # Don't list a function as having a race with itself (it automatically
        # does).
        delete $races_with{$function};
        if (keys %races_with) {

            my $race_text =
                "${output_function_name}has races with other threads"
              . " concurrently executing";
            my @race_names = sort name_order keys %races_with;
            if (@race_names == 1) {
                $race_text .= " either itself or " . $race_names[0];
            }
            else {
                $race_text .= " any of: itself, "
                           . join ", ", map { "$_()" } @race_names;
                $race_text =~ s/, (*nla:.*,) /, or/x;
            }

            $race_text = wrap($comment_columns, "", $hanging, "$race_text.");
            push @comments, split "\n", $race_text;
        }

        $need_exclusive = 1;
    }

    if ($this_data->{conditions}) {
            push @comments, "$function() macros only valid if "
                           . join ", ", $this_data->{conditions}->@*;
    }

    print $l "\n";

    if (@comments) {
        print $l "/* ", shift @comments;
        print $l map { "\n * $_" } @comments;
        print $l "\n" if @comments;
        print $l " */\n";
    }

    my $FUNC = uc $function;
    if ($this_data->{unsuitable}) {
        croak("Unsuitable function has a lock")
                            if $this_data->{locks} || $this_data->{categories};
        print $l "/*#define ${FUNC}_LOCK  assert(0)*/\n";
        delete $functions{$function};
        next;
    }

    # If we have a race but no other reason to lock, we do need a mutex; use
    # the default one
    if ($this_data->{races} && ! $this_data->{locks}) {
        $this_data->{locks}{$generic_lock} = 'r';
        $need_exclusive = 1;
    }

    if (! $this_data->{locks} && ! $this_data->{categories}) {
        print $l <<~EOT;
            #ifndef ${FUNC}_LOCK
            #  define ${FUNC}_LOCK    NOOP
            #  define ${FUNC}_UNLOCK  NOOP
            #endif
            EOT
        delete $functions{$function};
        next;
    }

    my $name = "";
    $name .= "gw" if $need_exclusive;

    my $env_lock = delete $this_data->{locks}{env};
    my $locale_lock = delete $this_data->{locks}{locale};

    # Currently those are the only two legal lock categories; the generic
    # lock currently must be one of them.
    croak("Unknown locks: ", Dumper $this_data->{locks})
                                                if $this_data->{locks}->%*;
    if ($env_lock) {
        $name .= "ENV" . $env_lock;
    }

    # Ready to output if no locale issues are involved
    if (! $locale_lock && ! $this_data->{categories}) {
    print STDERR __FILE__, ": ", __LINE__, ": ", $function, "\n";
        print $l <<~EOT;
            #ifndef ${FUNC}_LOCK
            #  define ${FUNC}_LOCK    ${name}_LOCK_
            #  define ${FUNC}_UNLOCK  ${name}_UNLOCK_
            #endif
            EOT
    }
    else {
    print STDERR __FILE__, ": ", __LINE__, ": ", $function, "\n";
        my $LOCK;
        if (! $env_lock && ! $locale_lock) {
            $LOCK = "TOGGLE_";
            $name = "TSE";
        }
        else {
            $LOCK = 'LOCK_';
            
            $name .= "_" if $env_lock;
            $locale_lock = 'r' unless $locale_lock;
            $name .= "LC" . $locale_lock;
        }

        my $category;
        if ( ! $this_data->{categories}
            || grep { $_ eq 'LC_ALL' } $this_data->{categories}->@*)
        {
            $category = "LC_ALL";
        }
        else {
            my @non_CTYPE = grep { $_ ne 'LC_TYPE' }
                                            $this_data->{categories}->@*;
            if (@non_CTYPE == 0) {
                $category = "LC_CTYPE";
            }
            elsif (@non_CTYPE > 1) {
                $category = "LC_ALL";
            }
            else {
                $category = $non_CTYPE[0];
            }
        }

        if ($category eq 'LC_ALL') {
    print STDERR __FILE__, ": ", __LINE__, ": ", $function, "\n";
            print $l <<~EOT;
                #ifndef ${FUNC}_LOCK
                #  define ${FUNC}_LOCK    ${name}_$LOCK(LC_ALL)
                #  define ${FUNC}_UNLOCK  ${name}_UN$LOCK(LC_ALL)
                #endif
                EOT
        }
        elsif ($category eq 'LC_CTYPE') {
            my $category = $this_data->{categories}[0];
            print $l <<~EOT;
                #ifndef ${FUNC}_LOCK
                #  ifdef $category
                #    define ${FUNC}_LOCK    ${name}_$LOCK($category)
                #    define ${FUNC}_UNLOCK  ${name}_UN$LOCK($category)
                #  else
                #    define ${FUNC}_LOCK    ${name}_$LOCK(LC_ALL)
                #    define ${FUNC}_UNLOCK  ${name}_UN$LOCK(LC_ALL)
                #  endif
                #endif
                EOT

            print $l <<~EOT;
                #ifndef ${FUNC}_LOCK
                #  ifdef PERL_MUST_DEAL_WITH
                #    define ${FUNC}_LOCK    ${name}_${LOCK}_CTYPE_AND($category)
                #    define ${FUNC}_UNLOCK  ${name}_UN${LOCK}_CTYPE_AND($category)
                #  elif defined($category)
                #    define ${FUNC}_LOCK    ${name}_$LOCK($category)
                #    define ${FUNC}_UNLOCK  ${name}_UN$LOCK($category)
                #  else
                #    define ${FUNC}_LOCK    ${name}_$LOCK(LC_ALL)
                #    define ${FUNC}_UNLOCK  ${name}_UN$LOCK(LC_ALL)
                #  endif
                #endif
                EOT
        }
    }

    print STDERR __FILE__, ": ", __LINE__, ": ", $function, "\n";
    delete $functions{$function};
}

if (%functions) {
    carp ("These functions unhandled: " . join ", ", keys %functions);
}

read_only_bottom_close_and_rename($l);

# Some of these are not thread-safe if called with arguments that don't
# comply with certain (easily-met) restrictions.  Those are commented where
# their res# There are also two mutex columns.  They give what mutexes should be invoked
# so as to prevent the function from interfering with other threads.  The
# first is for when the non-reentrant function is called; and the second for
# the reentrant version.  The values were gleaned by looking at the POSIX
# Standard and the ATTRIBUTES section of the glibc man pages for the
# functions.  In many cases the Standard says a function is thread safe, but the
# glibc says they are only so if the locale and environment aren't changed
# during their execution.   The Standard says

#   A thread-safe function can be safely invoked concurrently with other calls
#   to the same function, or with calls to any other thread-safe functions, by
#   multiple threads. Each function defined in the System Interfaces volume of
#   POSIX.1-2017 is thread-safe unless explicitly stated otherwise. Examples
#   are any 'pure' function, a function which holds a mutex locked while it is
#   accessing static storage, or objects shared among threads.

# If you read that carefully, it implies that any non-thread-safe function,
# even completely unrelated ones, executed by another thread can render your
# thread's allegedly thread-safe function unsafe.  Changing the locale or
# environment are unsafe, so maybe glibc is technically in compliance.

# So the implementations here are based on the more restrictive glibc ones.
# khw hopes that there aren't other platforms with more restrictive needs.
# But if a platform required further restrictions, the table could be modified
# to make all platforms share the most restrictive version.  For some of the
# functions, the reentrant version is a GNU extension, with some other
# platforms offering similar extensions.

# XXX It could well be that the thread-safe uselocale() that changes the
# locale doesn't render these functions non-thread safe, so a future direction
# would be to check that out, and change things accordingly.

# Each mutex column may contain 3 single-capital-letter flags, possibly
# appended with lowercase modifiers.  The meanings of two of the flags are:

#   E   involves the Env mutex 
#   L   involves the Locale mutex 

# It so happens that these are the only two mutexes any of these functions are
# involved in.  For these two, the capital letter must have one of two
# lowercase suffixes:

#   r   The function is affected by changes given by the type of the mutex,
#       but doesn't itself make any changes.  Hence, a read-only mutex
#       suffices to prevent cross thread interference.
#   w   The function actually makes changes that would affect other threads
#       using this mutex type, so an exclusive (writer) mutex is required

# The third flag, R, if present, indicates that there is a potential race
# (inherent in the function) with other threads.  The R flag may stand alone,
# or be followed by a sequence of lower case letters, which together form a
# name.  If it stands alone, the function has a potential race with just
# itself being called in another thread.  It also may return its value in a
# global static buffer, or be affected by signals, but those details don't
# affect how we handle things, so there is no need to include them in the
# table below.

# If R is followed by a name, it means there is a potential race with other
# functions which also are tagged by the same name in the table.  The special
# name 'l' as in 'Rl' indicates that the race is related to locales; otherwise
# it uses the default described in the next paragraph.

# It would be most efficient if a separate mutex was created for each entry
# that has an R flag, except those that share the same R tag would be grouped
# together in one mutex.  But that isn't done currently, for two reasons:
#  1)   khw believes that these are rarely enough called that they can share a
#       mutex without slowing down a process noticeably.  And there is an
#       existing mutex that khw also believes isn't used much, and so that is
#       pressed into service as the default for all of them.  If this turns
#       out to be wrong, mutexes could be created for any subset(s) of them.
#  2)   But the fewer mutexes there are, the less likely there is for
#       deadlock.  If you acquire mutex A and somebody else acquires mutex B
#       and then you need B; and they need A, you have deadlock.  But if A and
#       B are collapsed into just A; there is no possibility of deadlock.
#       (The locale and environment mutexes are the only ones perl is likely to
#       use together, and the possibility of deadlock is minimized by using
#       special macros to lock both, constructed so that locale is always
#       locked first, and the code is constructed so that the the locale is never attempted to be while 
#       And almost all calls 

# Macros that define the appropriate locks are defined, but it is up to the
# user of the functions to include them in code.  There is too much variance
# in how these might be used for the code to try to guess what to do.  What
# this does do though, is to #define the appropriate macro that does the
# correct locking around a call, so that the coder doesn't have to know if the
# reentrant version is used or not.

# Many of the functions open a database.  In actuality, the entire transaction
# through the corresponding closing of the database should be in one
# critical section.  But if this is long, it could keep other threads from
# executing.  Some of that could be fixed by making a separate mutex for them.
# But still many rely on the environment and/or locale not changing during the
# operation, so would lock out writers to those.
__DATA__
addmntent  	| Rstream Lr
alphasort  	| Lr
asctime  	| Rasctime Lr
asctime_r  	| Lr
asprintf  	| Lr
atof  	        | Lr
atoi        	| Lr
atoll       	| Lr
atol        	| Lr
btowc           | LC_CTYPE
#ifndef __GLIBC__
basename        | R
#endif
#ifndef __GLIBC__
catgets         | R
#endif

catopen  	| Er LC_MESSAGES
clearenv  	| Ew
clearerr_unlocked| Rstream
crypt_gensalt	| Rcrypt_gensalt
crypt       	| Rcrypt
ctime_r  	| R Er Lr   //  'R' because some implementations may call tzset
ctime       	| Rtmbuf Rasctime Er Lr
cuserid  	| Rcuserid/!string Lr
dbm_clearerr,   | R
dbm_close,
dbm_delete,
dbm_error,
dbm_fetch,
dbm_firstkey,
dbm_nextkey,
dbm_open,
dbm_store
#ifndef __GLIBC__
dirname         | Lr
#endif
#ifndef __GLIBC__
dlerror         | R
#endif
drand48  	| Rdrand48
drand48_r  	| Rbuffer
ecvt        	| Recvt
encrypt  	| Rcrypt
endaliasent  	| Lr
endfsent  	| Rfsent
endgrent  	| Rgrent Lr
endhostent  	| Rhostent Er Lr
endnetent  	| Rnetent Er Lr
endnetgrent  	| Rnetgrent
endprotoent  	| Rprotoent Lr
endpwent        | Rpwent Lr
endrpcent  	| Lr
endservent  	| Rservent Lr
endspent  	| Rgetspent Lr
endttyent  	| Rttyent
endusershell  	| U
endutent,       | Rutent
endutxent
erand48  	| Rdrand48
erand48_r  	| Rbuffer
err  	        | Lr
error_at_line  	| Rerror_at_line/error_one_per_line Lr
error       	| Lr
errx        	| Lr
ether_aton  	| U
ether_ntoa  	| U
execlp  	| Er
execvpe  	| Er
execvp  	| Er
exit        	| Rexit
__fbufsize  	| Rstream
fcloseall  	| Rstreams
fcvt        	| Rfcvt
fflush_unlocked | Rstream
fgetc_unlocked  | Rstream
fgetgrent  	| Rfgetgrent
fgetpwent  	| Rfgetpwent
fgetspent  	| Rfgetspent
fgets_unlocked  | Rstream
fgetwc_unlocked | Rstream
fgetwc, getwc   | LC_CTYPE 
fgetws_unlocked | Rstream
fgetws          | LC_CTYPE
fnmatch  	| Er Lr
forkpty  	| Lr
__fpending  	| Rstream
__fpurge  	| Rstream
fputc_unlocked  | Rstream
fputs_unlocked  | Rstream
fputwc_unlocked | Rstream
putwc, fputwc   | LC_CTYPE
fputws_unlocked | Rstream
fputws          | LC_CTYPE
fread_unlocked  | Rstream
__fsetlocking  	| Rstream
fts_children  	| U
fts_read  	| U
ftw             | R
fwrite_unlocked | Rstream
fwscanf,        | Lr LC_NUMERIC
swscanf,
wscanf
gammaf,         | Rsigngam
gammal,
gamma,
lgammaf,
lgammal,
lgamma
getaddrinfo  	| Er Lr
getaliasbyname_r| Lr
getaliasbyname  | U
getaliasent_r  	| Lr
getaliasent  	| U
getchar_unlocked| Rstdin
getcontext  	| Rucp
getc_unlocked  	| Rstream
get_current_dir_name | Er
getdate_r  	| Er Lr LC_TIME
getdate  	| Rgetdate Er Lr LC_TIME
getenv  	| Er
getfsent  	| Rfsent Lr
getfsfile  	| Rfsent Lr
getfsspec  	| Rfsent Lr
getgrent  	| Rgrent Rgrentbuf Lr
getgrent_r  	| Rgrent Lr
getgrgid  	| Rgrgid Lr
getgrgid_r  	| Lr
getgrnam  	| Rgrnam Lr
getgrnam_r  	| Lr
getgrouplist  	| Lr
gethostbyaddr_r | Er Lr
gethostbyaddr  	| Rhostbyaddr Er Lr
gethostbyname2_r| Er Lr
gethostbyname2  | Rhostbyname2 Er Lr
gethostbyname_r | Er Lr
gethostbyname  	| Rhostbyname Er Lr
gethostent  	| Rhostent Rhostentbuf Er Lr
gethostent_r  	| Rhostent Er Lr
gethostid  	| hostid Er Lr
getlogin  	| Rgetlogin Rutent sig:ALRM timer Lr
getlogin_r  	| Rutent sig:ALRM timer Lr
getmntent_r  	| Lr
getmntent  	| Rmntentbuf Lr
getnameinfo  	| Er Lr
getnetbyaddr_r  | Lr
getnetbyaddr  	| Rnetbyaddr Lr
getnetbyname_r  | Lr
getnetbyname  	| Rnetbyname Er Lr
getnetent_r  	| Lr
getnetent  	| Rnetent Rnetentbuf Er Lr
getnetgrent  	| Rnetgrent Rnetgrentbuf Lr
getnetgrent_r  	| Rnetgrent Lr
getopt_long_only| Rgetopt Er
getopt_long  	| Rgetopt Er
getopt  	| Rgetopt Er
getpass  	| term
getprotobyname_r| Lr
getprotobyname  | Rprotobyname Lr
getprotobynumber_r| Lr
getprotobynumber| Rprotobynumber Lr
getprotoent_r  	| Lr
getprotoent  	| Rprotoent Rprotoentbuf Lr
getpwent  	| Rpwent Rpwentbuf Lr
getpwent_r  	| Rpwent Lr
getpw       	| Lr
getpwnam_r  	| Lr
getpwnam  	| Rpwnam Lr
getpwuid_r  	| Lr
getpwuid  	| Rpwuid Lr
getrpcbyname_r  | Lr
getrpcbyname  	| U
getrpcbynumber_r| Lr
getrpcbynumber  | U
getrpcent_r  	| Lr
getrpcent  	| U
getrpcport  	| Er Lr
getservbyname_r | Lr
getservbyname  	| Rservbyname Lr
getservbyport_r | Lr
getservbyport  	| Rservbyport Lr
getservent_r  	| Lr
getservent  	| Rservent Rserventbuf Lr
getspent  	| Rgetspent Rspentbuf Lr
getspent_r  	| Rgetspent Lr
getspnam  	| Rgetspnam Lr
getspnam_r  	| Lr
getttyent  	| Rttyent
getttynam  	| Rttyent
getusershell  	| U
getutent, getutxent| init Rutent Rutentbuf sig:ALRM timer
getutid, getutxid| init Rutent sig:ALRM timer
getutline  	| init Rutent sig:ALRM timer
getwchar_unlocked| Rstdin
getwchar        | LC_CTYPE
getwc_unlocked  | Rstream
glob  	        | Rutent Er sig:ALRM timer Lr LC_COLLATE
gmtime_r  	| Er Lr
gmtime  	| Rtmbuf Er Lr
grantpt  	| Lr
hcreate  	| Rhsearch
hcreate_r  	| Rhtab
hdestroy  	| Rhsearch
hdestroy_r  	| Rhtab
hsearch  	| Rhsearch
hsearch_r  	| Rhtab
iconv_open  	| Lr
iconv       	| Rcd
inet_addr  	| Lr
inet_aton  	| Lr
inet_network  	| Lr
inet_ntoa  	| R Lr
inet_ntop  	| Lr
inet_pton  	| Lr
initgroups  	| Lr
initstate_r  	| Rbuf
innetgr  	| Rnetgrent Lr
iruserok_af  	| Lr
iruserok  	| Lr
isalpha, isalnum,| LC_CTYPE
isascii, isblank,
iscntrl, isdigit,
isgraph, islower,
isprint, ispunct,
isspace, isupper,
isxdigit, isalnum_l,
isalpha_l, isascii_l,
isblank_l, iscntrl_l,
isdigit_l, isgraph_l,
islower_l, isprint_l,
ispunct_l, isspace_l,
isupper_l, isxdigit_l
iswalnum, iswalpha,| Lr LC_CTYPE
iswascii, iswblank,
iswcntrl, iswdigit,
iswgraph, iswlower,
iswprint, iswpunct,
iswspace, iswupper,
iswxdigit, iswalnum_l,
iswalpha_l, iswascii_l,
iswblank_l, iswcntrl_l,
iswdigit_l, iswgraph_l,
iswlower_l, iswprint_l,
iswpunct_l, iswspace_l,
iswupper_l, iswxdigit_l
jrand48  	| Rdrand48
jrand48_r  	| Rbuffer
l64a  	        | Rl64a
lcong48  	| Rdrand48
lcong48_r  	| Rbuffer
localeconv  	| Rlocaleconv Lr LC_NUMERIC LC_MONETARY
localtime_r  	| R Er Lr   // 'R' because some implementations may call tzset
localtime  	| Rtmbuf Er Lr
login       	| Rutent sig:ALRM timer
login_tty  	| Rttyname
logout  	| Rutent sig:ALRM timer
logwtmp  	| sig:ALRM timer
lrand48  	| Rdrand48
lrand48_r  	| Rbuffer
makecontext  	| Rucp
mallinfo  	| init const:mallopt
MB_CUR_MAX      | LC_CTYPE
mblen  	        | R LC_CTYPE
mbrlen  	| Rmbrlen/!ps LC_CTYPE
mbrtowc         | LC_CTYPE Rmbrtowc/!ps
mbsinit         | LC_CTYPE
mbsnrtowcs  	| Rmbsnrtowcs/!ps LC_CTYPE
mbsrtowcs  	| Rmbsrtowcs/!ps LC_CTYPE
mbstowcs        | LC_CTYPE
mbtowc          | R LC_CTYPE
mcheck_check_all| Rmcheck const:malloc_hooks
mcheck_pedantic | Rmcheck const:malloc_hooks
mcheck  	| Rmcheck const:malloc_hooks
mktime  	| R Er Lr   // 'R' because calls tzset
mprobe  	| Rmcheck const:malloc_hooks
mrand48  	| Rdrand48
mrand48_r  	| Rbuffer
mtrace  	| U
muntrace  	| U
nftw        	| cwd
newlocale  	| Er
nl_langinfo  	| R Lr
nrand48  	| Rdrand48
nrand48_r  	| Rbuffer
openpty  	| Lr
perror  	| Rstderr
posix_fallocate | N may be unsafe on some platforms
printf, fprintf,| LC_NUMERIC Lr
dprintf, sprintf,
snprintf, vprintf,
vfprintf, vdprintf,
vsprintf, vsnprintf
profil  	| U
psiginfo  	| Lr
psignal  	| Lr
ptsname  	| Rptsname
putchar_unlocked| Rstdout
putc_unlocked  	| Rstream
putenv  	| Ew
putpwent  	| Lr
putspent  	| Lr
pututline,      | Rutent sig:ALRM timer
pututxline
putwchar        | LC_CTYPE
putwchar_unlocked| Rstdout
putwc_unlocked  | Rstream
pvalloc  	| init
qecvt  	        | Rqecvt
qfcvt       	| Rqfcvt
random_r  	| Rbuf
rcmd_af  	| U
rcmd        	| U
readdir  	| Rdirstream
re_comp         | U
re_exec  	| U
regcomp  	| Lr
regerror  	| Er
regexec  	| Lr
res_nclose  	| Lr
res_ninit  	| Lr
res_nquerydomain| Lr
res_nquery  	| Lr
res_nsearch  	| Lr
res_nsend  	| Lr
rexec_af  	| U
rexec  	        | U
rpmatch         | LC_MESSAGES Lr
ruserok_af  	| Lr
ruserok  	| Lr
scanf, fscanf,  | Lr LC_NUMERIC
sscanf, vscanf,
vsscanf, vfscanf
secure_getenv  	| Er
seed48  	| Rdrand48
seed48_r  	| Rbuffer
setaliasent  	| Lr
setcontext  	| Rucp
setenv  	| Ew
setfsent  	| Rfsent
setgrent  	| Rgrent Lr
sethostent  	| Rhostent Er Lr
sethostid  	| const:hostid
setkey  	| Rcrypt
setlocale  	| Lw Er
setlogmask  	| RLogMask
setnetent  	| Rnetent Er Lr
setnetgrent  	| Rnetgrent Lr
setprotoent  	| Rprotoent Lr
setpwent        | Rpwent Lr
setrpcent  	| Lr
setservent  	| Rservent Lr
setspent  	| Rgetspent Lr
setstate_r  	| Rbuf
setttyent  	| Rttyent
setusershell  	| U
setutent, setutxent| Rutent
sgetspent_r  	| Lr
sgetspent  	| Rsgetspent
shm_open  	| Lr
shm_unlink  	| Lr
siginterrupt  	| const:sigintr
sleep       	| sig:SIGCHLD/linux
srand48  	| Rdrand48
srand48_r  	| Rbuffer
srandom_r  	| Rbuf
ssignal  	| sigintr
strcasecmp,     | Lr LC_CTYPE
strncasecmp
strcasestr  	| Lr
strcoll, wcscoll| Lr LC_COLLATE
strerror        | Rstrerror LC_MESSAGES
strerror_r,     | LC_MESSAGES
strerror_l
strfmon         | LC_MONETARY Lr
strfmon_l       | LC_MONETARY
strfromd,       | Lr LC_NUMERIC
strfromf, strfroml
strftime  	| R Er Lr LC_TIME // 'R' because some implementations may call
                                  // tzset
strftime_l  	| LC_TIME
strptime  	| Er Lr LC_TIME
strsignal  	| Rstrsignal Lr LC_MESSAGES
strtod  	| Lr LC_NUMERIC
strtof  	| Lr LC_NUMERIC
strtoimax  	| Lr
strtok  	| Rstrtok
strtold  	| Lr LC_NUMERIC
wcstod, wcstold,| Lr LC_NUMERIC
wcstof
strtoll  	| Lr
strtol  	| Lr
strtoq  	| Lr
strtoull  	| Lr
strtoul  	| Lr
strtoumax  	| Lr
strtouq  	| Lr
strverscmp      | LC_COLLATE
strxfrm  	| Lr LC_COLLATE LC_CTYPE
wcsxfrm         | Lr LC_COLLATE LC_CTYPE
swapcontext  	| Roucp Rucp
sysconf  	| Er
syslog  	| Er Lr
tdelete  	| Rrootp
tempnam  	| Er
tfind  	        | Rrootp
timegm  	| Er Lr
timelocal  	| Er Lr
tmpnam  	| Rtmpnam/!s
toupper, tolower,| LC_CTYPE
toupper_l, tolower_l
towctrans       | LC_CTYPE
towlower, towupper| Lr LC_CTYPE
towlower_l, towupper_l| LC_CTYPE
tsearch  	| Rrootp
ttyname  	| Rttyname
ttyslot  	| U
twalk  	        | Rroot
twalk_r  	| Rroot

// The POSIX Standard says:
//
//    "If a thread accesses tzname, daylight, or timezone  directly while
//     another thread is in a call to tzset(), or to any function that is
//     required or allowed to set timezone information as if by calling tzset(),
//     the behavior is undefined."
//
// Further,
//
//    "The tzset() function shall use the value of the environment variable TZ
//     to set time conversion information used by ctime, localtime, mktime, and
//     strftime. If TZ is absent from the environment, implementation-defined
//     default timezone information shall be used.
//
// This means that tzset() must have an exclusive lock, as well as the others
// listed that call it.
tzset  	        | R Er Lr

// Don't know why this entry appeared: ungetwc LC_CTYPE
unsetenv  	| Ew
updwtmp  	| sig:ALRM timer
utmpname  	| Rutent

// khw believes that this function is thread-safe if called with a per-thread
// argument
va_arg  	| Rap/arg-ap-is-locale-to-its-thread
valloc  	| init
vasprintf  	| Lr
verr  	        | Lr
verrx       	| Lr
versionsort  	| Lr
vsyslog  	| Er Lr
vwarn       	| Lr
vwarnx  	| Lr
warn        	| Lr
warnx       	| Lr
wcrtomb  	| Rwcrtomb/!ps LC_CTYPE
wcscasecmp  	| Lr LC_CTYPE
wcsncasecmp  	| Lr LC_CTYPE
wcsnrtombs  	| Rwcsnrtombs/!ps LC_CTYPE
wcsrtombs  	| Rwcsrtombs/!ps LC_CTYPE
wcstoimax  	| Lr
wcstombs        | LC_CTYPE
wcstoumax  	| Lr
wcswidth  	| Lr LC_CTYPE
wctob           | LC_CTYPE
wctomb  	| R LC_CTYPE
wctrans  	| Lr LC_CTYPE
wctype  	| Lr LC_CTYPE
wcwidth  	| Lr LC_CTYPE
wordexp  	| Rutent Ew sig:ALRM timer Lr
wprintf, fwprintf,| Lr LC_CTYPE LC_NUMERIC
swprintf, vwprintf,
vfwprintf, vswprintf
scandir         | LC_CTYPE LC_COLLATE
wcschr          | LC_CTYPE
wcsftime        | LC_CTYPE LC_TIME
wcsrchr         | LC_CTYPE

__END__
<a href="../functions/system.html"><i>system</i>()</a><br>
<a href="../functions/rand.html"><i>rand</i>()</a><br>  Unclear why unsafe
       │l64a()    │ Thread safety │ MT-Unsafe race:l64a │
       │asprintf(), vasprintf() │ Thread safety │ MT-Safe locale │
       │atof()    │ Thread safety │ MT-Safe locale │
       ├────────────────────────┼───────────────┼────────────────┤
       │atoi(), atol(), atoll() │ Thread safety │ MT-Safe locale │
       │bindresvport() │ Thread safety │ glibc >= 2.17: MT-Safe  │
       │               │               │ glibc < 2.17: MT-Unsafe │
       ├──────────┼───────────────┼─────────────────────┤
       │catopen()  │ Thread safety │ MT-Safe env │
       │cfree()   │ Thread safety │ MT-Safe // In glibc  │
       ├──────────┼───────────────┼─────────────────────┤
       │clearenv() │ Thread safety │ MT-Unsafe const:env │
       ├──────────────────┼───────────────┼──────────────────────────────┤
       │crypt              │ Thread safety │ MT-Unsafe race:crypt │
       ├──────────────────┼───────────────┼──────────────────────────────┤
       │crypt_gensalt     │ Thread safety │ MT-Unsafe race:crypt_gensalt │
       │asctime()      │ Thread safety │ MT-Unsafe race:asctime locale   │
       ├───────────────┼───────────────┼─────────────────────────────────┤
       │asctime_r()    │ Thread safety │ MT-Safe locale                  │
       ├───────────────┼───────────────┼─────────────────────────────────┤
       │ctime()        │ Thread safety │ MT-Unsafe race:tmbuf            │
       │               │               │ race:asctime env locale         │
       ├───────────────┼───────────────┼─────────────────────────────────┤
       │ctime_r(), gm‐ │ Thread safety │ MT-Safe env locale              │
       │time_r(), lo‐  │               │                                 │
       │caltime_r(),   │               │                                 │
       │mktime()       │               │                                 │
       ├───────────────┼───────────────┼─────────────────────────────────┤
       │gmtime(), lo‐  │ Thread safety │ MT-Unsafe race:tmbuf env locale │
       │caltime()      │               │                                 │
       ├──────────────────────┼───────────────┼────────────────────────┤
       │drand48(), erand48(), │ Thread safety │ MT-Unsafe race:drand48 │
       │lrand48(), nrand48(), │               │                        │
       │mrand48(), jrand48(), │               │                        │
       │srand48(), seed48(),  │               │                        │
       │lcong48()             │               │                        │
       ├──────────────────────────┼───────────────┼─────────────────────┤
       │drand48_r(), erand48_r(), │ Thread safety │ MT-Safe race:buffer │
       │lrand48_r(), nrand48_r(), │               │                     │
       │mrand48_r(), jrand48_r(), │               │                     │
       │srand48_r(), seed48_r(),  │               │                     │
       │lcong48_r()               │               │                     │
       ├──────────────────────────┼───────────────┼─────────────────────┤
       │ecvt()    │ Thread safety │ MT-Unsafe race:ecvt │
       ├──────────┼───────────────┼─────────────────────┤
       │fcvt()    │ Thread safety │ MT-Unsafe race:fcvt │
       ├──────────────────────────┼───────────────┼─────────────────────┤
       │encrypt(), setkey()     │ Thread safety │ MT-Unsafe race:crypt │
       ├──────────────────┼───────────────┼────────────────┤
       │err(), errx(),    │ Thread safety │ MT-Safe locale │
       │warn(), warnx(),  │               │                │
       │verr(), verrx(),  │               │                │
       │vwarn(), vwarnx() │               │                │
       ├────────────────┼───────────────┼───────────────────────────────────┤
       │error()         │ Thread safety │ MT-Safe locale                    │
       ├────────────────┼───────────────┼───────────────────────────────────┤
       │error_at_line() │ Thread safety │ MT-Unsafe race: error_at_line/er‐ │
       │                │               │ ror_one_per_line locale           │
       ├──────────────────────────────────┼───────────────┼───────────┤
       │ether_aton(), ether_ntoa()        │ Thread safety │ MT-Unsafe │
       ├──────────────────────────────┼───────────────┼─────────────┤
       │execlp(), execvp(), execvpe() │ Thread safety │ MT-Safe env │
       ├──────────┼───────────────┼─────────────────────┤
       │exit()    │ Thread safety │ MT-Unsafe race:exit │
       ├──────────────────────────┼───────────────┼─────────────────────┤
       │fcloseall() │ Thread safety │ MT-Unsafe race:streams │
       ├──────────────────────────┼───────────────┼─────────────────────┤
       │fgetgrent() │ Thread safety │ MT-Unsafe race:fgetgrent │
       ├────────────┼───────────────┼──────────────────────────┤
       │fgetpwent() │ Thread safety │ MT-Unsafe race:fgetpwent │
       ├──────────────────────────┼───────────────┼─────────────────────┤
       │fmtmsg()  │ Thread safety │ glibc >= 2.16: MT-Safe  │
       │          │               │ glibc < 2.16: MT-Unsafe │
       ├──────────┼───────────────┼────────────────────┤
       │fnmatch() │ Thread safety │ MT-Safe env locale │
       ├───────────┼───────────────┼─────────────────────┤
       │__fpurge() │ Thread safety │ MT-Safe race:stream │
       ├───────────────────────────────────┼───────────────┼───────────┤
       │fts_read(), fts_children()         │ Thread safety │ MT-Unsafe │
       ├──────────┼───────────────┼─────────────┤
       │nftw()    │ Thread safety │ MT-Safe cwd │
       ├────────────────────────────┼───────────────┼────────────────────────┤
       │gamma(), gammaf(), gammal() │ Thread safety │ MT-Unsafe race:signgam │
       ├────────────────┼───────────────┼────────────────────┤
       │getaddrinfo()   │ Thread safety │ MT-Safe env locale │
       ├───────────────────────────┼───────────────┼──────────────────┤
       │getcontext(), setcontext() │ Thread safety │ MT-Safe race:ucp │
       ├───────────────────────┼───────────────┼─────────────┤
       │get_current_dir_name() │ Thread safety │ MT-Safe env │
       ├────────────┼───────────────┼───────────────────────────────────┤
       │getdate()   │ Thread safety │ MT-Unsafe race:getdate env locale │
       ├────────────┼───────────────┼───────────────────────────────────┤
       │getdate_r() │ Thread safety │ MT-Safe env locale                │
       ├──────────────────────────┼───────────────┼─────────────┤
       │getenv(), secure_getenv() │ Thread safety │ MT-Safe env │
       ├─────────────┼───────────────┼─────────────────────────────┤
       │endfsent(),  │ Thread safety │ MT-Unsafe race:fsent        │
       │setfsent()   │               │                             │
       ├─────────────┼───────────────┼─────────────────────────────┤
       │getfsent(),  │ Thread safety │ MT-Unsafe race:fsent locale │
       │getfsspec(), │               │                             │
       │getfsfile()  │               │                             │
       ├──────────────────────────┼───────────────┼─────────────────────┤
       │getgrent()  │ Thread safety │ MT-Unsafe race:grent        │
       │            │               │ race:grentbuf locale        │
       ├────────────┼───────────────┼─────────────────────────────┤
       │setgrent(), │ Thread safety │ MT-Unsafe race:grent locale │
       │endgrent()  │               │                             │
       ├──────────────────────────┼───────────────┼─────────────────────┤
       │getgrent_r()  │ Thread safety │ MT-Unsafe race:grent locale │
       ├──────────────┼───────────────┼─────────────────────────────┤
       │getgrnam()    │ Thread safety │ MT-Unsafe race:grnam locale │
       ├──────────────┼───────────────┼─────────────────────────────┤
       │getgrgid()    │ Thread safety │ MT-Unsafe race:grgid locale │
       ├──────────────┼───────────────┼─────────────────────────────┤
       │getgrnam_r(), │ Thread safety │ MT-Safe locale              │
       │getgrgid_r()  │               │                             │
       ├───────────────┼───────────────┼────────────────┤
       │getgrouplist() │ Thread safety │ MT-Safe locale │
       ├───────────────────┼───────────────┼───────────────────────────────┤
       │gethostbyname()    │ Thread safety │ MT-Unsafe race:hostbyname env │
       │                   │               │ locale                        │
       ├───────────────────┼───────────────┼───────────────────────────────┤
       │gethostbyaddr()    │ Thread safety │ MT-Unsafe race:hostbyaddr env │
       │                   │               │ locale                        │
       ├───────────────────┼───────────────┼───────────────────────────────┤
       │sethostent(),      │ Thread safety │ MT-Unsafe race:hostent env    │
       │endhostent(),      │               │ locale                        │
       │gethostent_r()     │               │                               │
       ├───────────────────┼───────────────┼───────────────────────────────┤
       │gethostent()       │ Thread safety │ MT-Unsafe race:hostent        │
       │                   │               │ race:hostentbuf env locale    │
       ├───────────────────┼───────────────┼───────────────────────────────┤
       │gethostbyname2()   │ Thread safety │ MT-Unsafe race:hostbyname2    │
       │                   │               │ env locale                    │
       ├───────────────────┼───────────────┼───────────────────────────────┤
       │gethostbyaddr_r(), │ Thread safety │ MT-Safe env locale            │
       │gethostbyname_r(), │               │                               │
       │gethostbyname2_r() │               │                               │
       ├──────────────────────────┼───────────────┼─────────────────────┤
       │gethostid() │ Thread safety │ MT-Safe hostid env locale │
       ├────────────┼───────────────┼───────────────────────────┤
       │sethostid() │ Thread safety │ MT-Unsafe const:hostid    │
       ├──────────────────────────┼───────────────┼─────────────────────┤
       │getlogin()   │ Thread safety │ MT-Unsafe race:getlogin race:utent    │
       │             │               │ sig:ALRM timer locale                 │
       ├─────────────┼───────────────┼───────────────────────────────────────┤
       │getlogin_r() │ Thread safety │ MT-Unsafe race:utent sig:ALRM timer   │
       │             │               │ locale                                │
       ├─────────────┼───────────────┼───────────────────────────────────────┤
       │cuserid()    │ Thread safety │ MT-Unsafe race:cuserid/!string locale │
       ├──────────────────────────┼───────────────┼─────────────────────┤
       │getmntent()   │ Thread safety │ MT-Unsafe race:mntentbuf locale │
       ├──────────────┼───────────────┼─────────────────────────────────┤
       │addmntent()   │ Thread safety │ MT-Safe race:stream locale      │
       ├──────────────┼───────────────┼─────────────────────────────────┤
       │getmntent_r() │ Thread safety │ MT-Safe locale                  │
       ├──────────────────────────┼───────────────┼─────────────────────┤
       │getnameinfo() │ Thread safety │ MT-Safe env locale │
       ├───────────────┼───────────────┼───────────────────────────┤
       │getnetent()    │ Thread safety │ MT-Unsafe race:netent     │
       │               │               │ race:netentbuf env locale │
       ├───────────────┼───────────────┼───────────────────────────┤
       │getnetbyname() │ Thread safety │ MT-Unsafe race:netbyname  │
       │               │               │ env locale                │
       ├───────────────┼───────────────┼───────────────────────────┤
       │getnetbyaddr() │ Thread safety │ MT-Unsafe race:netbyaddr  │
       │               │               │ locale                    │
       ├───────────────┼───────────────┼───────────────────────────┤
       │setnetent(),   │ Thread safety │ MT-Unsafe race:netent env │
       │endnetent()    │               │ locale                    │
       ├──────────────────┼───────────────┼────────────────┤
       │getnetent_r(),    │ Thread safety │ MT-Safe locale │
       │getnetbyname_r(), │               │                │
       │getnetbyaddr_r()  │               │                │
       ├─────────────────────────┼───────────────┼───────────────────────────┤
       │getopt(), getopt_long(), │ Thread safety │ MT-Unsafe race:getopt env │
       │getopt_long_only()       │               │                           │
       ├──────────┼───────────────┼────────────────┤
       │getpass() │ Thread safety │ MT-Unsafe term │
       ├───────────────────┼───────────────┼──────────────────────────────┤
       │getprotoent()      │ Thread safety │ MT-Unsafe race:protoent      │
       │                   │               │ race:protoentbuf locale      │
       ├───────────────────┼───────────────┼──────────────────────────────┤
       │getprotobyname()   │ Thread safety │ MT-Unsafe race:protobyname   │
       │                   │               │ locale                       │
       ├───────────────────┼───────────────┼──────────────────────────────┤
       │getprotobynumber() │ Thread safety │ MT-Unsafe race:protobynumber │
       │                   │               │ locale                       │
       ├───────────────────┼───────────────┼──────────────────────────────┤
       │setprotoent(),     │ Thread safety │ MT-Unsafe race:protoent      │
       │endprotoent()      │               │ locale                       │
       ├─────────────────────┼───────────────┼────────────────┤
       │getprotoent_r(),     │ Thread safety │ MT-Safe locale │
       │getprotobyname_r(),  │               │                │
       │getprotobynumber_r() │               │                │
       ├──────────┼───────────────┼────────────────┤
       │getpw()   │ Thread safety │ MT-Safe locale │
       ├────────────┼───────────────┼─────────────────────────────┤
       │getpwent()  │ Thread safety │ MT-Unsafe race:pwent        │
       │            │               │ race:pwentbuf locale        │
       │setpwent(), │ Thread safety │ MT-Unsafe race:pwent locale │
       │endpwent()  │               │                             │
       ├──────────────┼───────────────┼─────────────────────────────┤
       │getpwent_r()  │ Thread safety │ MT-Unsafe race:pwent locale │
       ├──────────────┼───────────────┼─────────────────────────────┤
       │getpwnam()    │ Thread safety │ MT-Unsafe race:pwnam locale │
       ├──────────────┼───────────────┼─────────────────────────────┤
       │getpwuid()    │ Thread safety │ MT-Unsafe race:pwuid locale │
       ├──────────────┼───────────────┼─────────────────────────────┤
       │getpwnam_r(), │ Thread safety │ MT-Safe locale              │
       │getpwuid_r()  │               │                             │
       ├─────────────────────────────┼───────────────┼────────────────┤
       │getrpcent(), getrpcbyname(), │ Thread safety │ MT-Unsafe      │
       │getrpcbynumber()             │               │                │
       ├─────────────────────────────┼───────────────┼────────────────┤
       │setrpcent(), endrpcent()     │ Thread safety │ MT-Safe locale │
       ├────────────────────┼───────────────┼────────────────┤
       │getrpcent_r(),      │ Thread safety │ MT-Safe locale │
       │getrpcbyname_r(),   │               │                │
       │getrpcbynumber_r()  │               │                │
       ├─────────────┼───────────────┼────────────────────┤
       │getrpcport() │ Thread safety │ MT-Safe env locale │
       ├────────────────┼───────────────┼───────────────────────────┤
       │getservent()    │ Thread safety │ MT-Unsafe race:servent    │
       │                │               │ race:serventbuf locale    │
       ├────────────────┼───────────────┼───────────────────────────┤
       │getservbyname() │ Thread safety │ MT-Unsafe race:servbyname │
       │                │               │ locale                    │
       ├────────────────┼───────────────┼───────────────────────────┤
       │getservbyport() │ Thread safety │ MT-Unsafe race:servbyport │
       │                │               │ locale                    │
       ├────────────────┼───────────────┼───────────────────────────┤
       │setservent(),   │ Thread safety │ MT-Unsafe race:servent    │
       │endservent()    │               │ locale                    │
       ├───────────────────┼───────────────┼────────────────┤
       │getservent_r(),    │ Thread safety │ MT-Safe locale │
       │getservbyname_r(), │               │                │
       │getservbyport_r()  │               │                │
       ├──────────────┼───────────────┼────────────────────────────────┤
       │getspnam()    │ Thread safety │ MT-Unsafe race:getspnam locale │
       ├──────────────┼───────────────┼────────────────────────────────┤
       │getspent()    │ Thread safety │ MT-Unsafe race:getspent        │
       │              │               │ race:spentbuf locale           │
       ├──────────────┼───────────────┼────────────────────────────────┤
       │setspent(),   │ Thread safety │ MT-Unsafe race:getspent locale │
       │endspent(),   │               │                                │
       │getspent_r()  │               │                                │
       ├──────────────┼───────────────┼────────────────────────────────┤
       │fgetspent()   │ Thread safety │ MT-Unsafe race:fgetspent       │
       ├──────────────┼───────────────┼────────────────────────────────┤
       │sgetspent()   │ Thread safety │ MT-Unsafe race:sgetspent       │
       ├──────────────┼───────────────┼────────────────────────────────┤
       │putspent(),   │ Thread safety │ MT-Safe locale                 │
       │getspnam_r(), │               │                                │
       │sgetspent_r() │               │                                │
       ├──────────────┼───────────────┼────────────────────────────────┤
       │getttyent(), setttyent(), │ Thread safety │ MT-Unsafe race:ttyent │
       │endttyent(), getttynam()  │               │                       │
       ├────────────────────────────────┼───────────────┼───────────┤
       │getusershell(), setusershell(), │ Thread safety │ MT-Unsafe │
       │endusershell()                  │               │           │
       ├────────────┼───────────────┼──────────────────────────────┤
       │getutent()  │ Thread safety │ MT-Unsafe init race:utent    │
       │            │               │ race:utentbuf sig:ALRM timer │
       ├────────────┼───────────────┼──────────────────────────────┤
       │getutid(),  │ Thread safety │ MT-Unsafe init race:utent    │
       │getutline() │               │ sig:ALRM timer               │
       ├────────────┼───────────────┼──────────────────────────────┤
       │pututline() │ Thread safety │ MT-Unsafe race:utent         │
       │            │               │ sig:ALRM timer               │
       ├────────────┼───────────────┼──────────────────────────────┤
       │setutent(), │ Thread safety │ MT-Unsafe race:utent         │
       │endutent(), │               │                              │
       │utmpname()  │               │                              │
       ├───────────┼───────────────┼──────────────────────────┤
       │glob()     │ Thread safety │ MT-Unsafe race:utent env │
       │           │               │ sig:ALRM timer locale    │
       ├───────────┼───────────────┼──────────────────────────┤
       │grantpt() │ Thread safety │ MT-Safe locale │
       ├──────────┼───────────────┼─────────────────┤
       │ssignal() │ Thread safety │ MT-Safe sigintr │
       ├──────────────────────────┼───────────────┼────────────────────────┤
       │hcreate(), hsearch(),     │ Thread safety │ MT-Unsafe race:hsearch │
       │hdestroy()                │               │                        │
       ├──────────────────────────┼───────────────┼────────────────────────┤
       │hcreate_r(), hsearch_r(), │ Thread safety │ MT-Safe race:htab      │
       │hdestroy_r()              │               │                        │
       ├──────────┼───────────────┼─────────────────┤
       │iconv()   │ Thread safety │ MT-Safe race:cd │
       ├─────────────┼───────────────┼────────────────┤
       │iconv_open() │ Thread safety │ MT-Safe locale │
       ├───────────────────────────────┼───────────────┼────────────────┤
       │inet_aton(), inet_addr(),      │ Thread safety │ MT-Safe locale │
       │inet_network(), inet_ntoa()    │               │                │
       ├───────────────────────────────┼───────────────┼────────────────┤
       │inet_ntop() │ Thread safety │ MT-Safe locale │
       │inet_pton() │ Thread safety │ MT-Safe locale │
       ├─────────────┼───────────────┼────────────────┤
       │initgroups() │ Thread safety │ MT-Safe locale │
       ├───────────┼───────────────┼────────────────┤
       │iswalnum() │ Thread safety │ MT-Safe locale │
       ├───────────┼───────────────┼────────────────┤
       │iswalpha() │ Thread safety │ MT-Safe locale │
       ├───────────┼───────────────┼────────────────┤
       │iswblank() │ Thread safety │ MT-Safe locale │
       ├───────────┼───────────────┼────────────────┤
       │iswcntrl() │ Thread safety │ MT-Safe locale │
       ├───────────┼───────────────┼────────────────┤
       │iswdigit() │ Thread safety │ MT-Safe locale │
       ├───────────┼───────────────┼────────────────┤
       │iswgraph() │ Thread safety │ MT-Safe locale │
       ├───────────┼───────────────┼────────────────┤
       │iswlower() │ Thread safety │ MT-Safe locale │
       ├───────────┼───────────────┼────────────────┤
       │iswprint() │ Thread safety │ MT-Safe locale │
       ├───────────┼───────────────┼────────────────┤
       │iswpunct() │ Thread safety │ MT-Safe locale │
       ├──────────────────────────┼───────────────┼─────────────────────┤
       │iswspace() │ Thread safety │ MT-Safe locale │
       ├───────────┼───────────────┼────────────────┤
       │iswupper() │ Thread safety │ MT-Safe locale │
       ├────────────┼───────────────┼────────────────┤
       │iswxdigit() │ Thread safety │ MT-Safe locale │
       ├─────────────┼───────────────┼──────────────────────────────────┤
       │localeconv() │ Thread safety │ MT-Unsafe race:localeconv locale │
       ├──────────┼───────────────┼──────────────────────┤
       │login(),  │ Thread safety │ MT-Unsafe race:utent │
       │logout()  │               │ sig:ALRM timer       │
       ├──────────────┼───────────────┼────────────────────────────┤
       │makecontext() │ Thread safety │ MT-Safe race:ucp           │
       ├──────────────┼───────────────┼────────────────────────────┤
       │swapcontext() │ Thread safety │ MT-Safe race:oucp race:ucp │
       ├───────────┼───────────────┼──────────────────────────────┤
       │mallinfo() │ Thread safety │ MT-Unsafe init const:mallopt │
       ├──────────┼───────────────┼────────────────┤
       │mblen()   │ Thread safety │ MT-Unsafe race │
       ├──────────┼───────────────┼───────────────────────────┤
       │mbrlen()  │ Thread safety │ MT-Unsafe race:mbrlen/!ps │
       ├──────────┼───────────────┼────────────────────────────┤
       │mbrtowc() │ Thread safety │ MT-Unsafe race:mbrtowc/!ps │
       ├─────────────┼───────────────┼───────────────────────────────┤
       │mbsnrtowcs() │ Thread safety │ MT-Unsafe race:mbsnrtowcs/!ps │
       ├────────────┼───────────────┼──────────────────────────────┤
       │mbsrtowcs() │ Thread safety │ MT-Unsafe race:mbsrtowcs/!ps │
       ├──────────┼───────────────┼────────────────┤
       │mbtowc()  │ Thread safety │ MT-Unsafe race │
       ├─────────────────────────────┼───────────────┼───────────────────────┤
       │mcheck(), mcheck_pedantic(), │ Thread safety │ MT-Unsafe race:mcheck │
       │mcheck_check_all(), mprobe() │               │ const:malloc_hooks    │
       ├─────────────────────┼───────────────┼───────────┤
       │mtrace(), muntrace() │ Thread safety │ MT-Unsafe │
       ├──────────────┼───────────────┼────────────────┤
       │nl_langinfo() │ Thread safety │ MT-Safe locale │
       ├─────────────────────┼───────────────┼────────────────────────┤
       │forkpty(), openpty() │ Thread safety │ MT-Safe locale         │
       ├─────────────────────┼───────────────┼────────────────────────┤
       │login_tty()          │ Thread safety │ MT-Unsafe race:ttyname │
       ├──────────┼───────────────┼─────────────────────┤
       │perror()  │ Thread safety │ MT-Safe race:stderr │
       ├──────────────────┼───────────────┼─────────────────────────┤
       │posix_fallocate() │ Thread safety │ MT-Safe (but see NOTES) │
       ├─────────────────┼───────────────┼────────────────┤
       │valloc(),        │ Thread safety │ MT-Unsafe init │
       │pvalloc()        │               │                │
       ├────────────────────────┼───────────────┼────────────────┤
       │printf(), fprintf(),    │ Thread safety │ MT-Safe locale │
       │sprintf(), snprintf(),  │               │                │
       │vprintf(), vfprintf(),  │               │                │
       │vsprintf(), vsnprintf() │               │                │
       ├──────────┼───────────────┼───────────┤
       │profil()  │ Thread safety │ MT-Unsafe │
       ├──────────────────────┼───────────────┼────────────────┤
       │psignal(), psiginfo() │ Thread safety │ MT-Safe locale │
       ├────────────┼───────────────┼────────────────────────┤
       │ptsname()   │ Thread safety │ MT-Unsafe race:ptsname │
       ├──────────┼───────────────┼─────────────────────┤
       │putenv()  │ Thread safety │ MT-Unsafe const:env │
       ├───────────┼───────────────┼────────────────┤
       │putpwent() │ Thread safety │ MT-Safe locale │
       ├──────────┼───────────────┼──────────────────────┤
       │qecvt()   │ Thread safety │ MT-Unsafe race:qecvt │
       ├──────────┼───────────────┼──────────────────────┤
       │qfcvt()   │ Thread safety │ MT-Unsafe race:qfcvt │
       ├──────────┼───────────────┼──────────────────────┤
       │random_r(), srandom_r(),    │ Thread safety │ MT-Safe race:buf │
       │initstate_r(), setstate_r() │               │                  │
       ├────────────────────────────┼───────────────┼────────────────┤
       │rcmd(), rcmd_af()           │ Thread safety │ MT-Unsafe      │
       ├────────────────────────────┼───────────────┼────────────────┤
       │iruserok(), ruserok(),      │ Thread safety │ MT-Safe locale │
       │iruserok_af(), ruserok_af() │               │                │
       ├──────────┼───────────────┼──────────────────────────┤
       │readdir() │ Thread safety │ MT-Unsafe race:dirstream │
       ├─────────────────────┼───────────────┼───────────┤
       │re_comp(), re_exec() │ Thread safety │ MT-Unsafe │
       ├─────────────────────┼───────────────┼────────────────┤
       │regcomp(), regexec() │ Thread safety │ MT-Safe locale │
       ├─────────────────────┼───────────────┼────────────────┤
       │regerror()           │ Thread safety │ MT-Safe env    │
       ├───────────────────────────────────┼───────────────┼────────────────┤
       │res_ninit(),         res_nclose(), │ Thread safety │ MT-Safe locale │
       │res_nquery(),                      │               │                │
       │res_nsearch(), res_nquerydomain(), │               │                │
       │res_nsend()                        │               │                │
       ├────────────────────┼───────────────┼───────────┤
       │rexec(), rexec_af() │ Thread safety │ MT-Unsafe │
       ├──────────┼───────────────┼────────────────┤
       │rpmatch() │ Thread safety │ MT-Safe locale │
       ├──────────────────────────┼───────────────┼─────────────────────┤
       │alphasort(), versionsort() │ Thread safety │ MT-Safe locale │
       ├─────────────────────┼───────────────┼────────────────┤
       │scanf(), fscanf(),   │ Thread safety │ MT-Safe locale │
       │sscanf(), vscanf(),  │               │                │
       │vsscanf(), vfscanf() │               │                │
       ├────────────────────┼───────────────┼────────────────┤
       │setaliasent(), en‐  │ Thread safety │ MT-Safe locale │
       │daliasent(), getal‐ │               │                │
       │iasent_r(), getal‐  │               │                │
       │iasbyname_r()       │               │                │
       ├────────────────────┼───────────────┼────────────────┤
       │getaliasent(),      │ Thread safety │ MT-Unsafe      │
       │getaliasbyname()    │               │                │
       ├──────────────┼───────────────┼─────────────────────┤
       │setenv(), un‐ │ Thread safety │ MT-Unsafe const:env │
       │setenv()      │               │                     │
       ├────────────┼───────────────┼────────────────────────────┤
       │setlocale() │ Thread safety │ MT-Unsafe const:locale env │
       ├─────────────┼───────────────┼────────────────────────┤
       │setlogmask() │ Thread safety │ MT-Unsafe race:LogMask │
       ├─────────────────┼───────────────┼─────────────────────────┤
       │setnetgrent(),   │ Thread safety │ MT-Unsafe race:netgrent │
       │getnetgrent_r(), │               │ locale                  │
       │innetgr()        │               │                         │
       ├─────────────────┼───────────────┼─────────────────────────┤
       │endnetgrent()    │ Thread safety │ MT-Unsafe race:netgrent │
       ├─────────────────┼───────────────┼─────────────────────────┤
       │getnetgrent()    │ Thread safety │ MT-Unsafe race:netgrent │
       │                 │               │ race:netgrentbuf locale │
       ├─────────────────────────┼───────────────┼────────────────┤
       │shm_open(), shm_unlink() │ Thread safety │ MT-Safe locale │
       ├───────────────┼───────────────┼─────────────────────────┤
       │siginterrupt() │ Thread safety │ MT-Unsafe const:sigintr │
       ├──────────┼───────────────┼─────────────────────────────┤
       │sleep()   │ Thread safety │ MT-Unsafe sig:SIGCHLD/linux │
       ├──────────────────────┼───────────────┼─────────────────┤
       │va_arg()              │ Thread safety │ MT-Safe race:ap │
       ├─────────────────────────────┼───────────────┼─────────────────────┤
       │__fbufsize(), __fpending(),  │ Thread safety │ MT-Safe race:stream │
       │__fpurge(), __fsetlocking()  │               │                     │
       ├─────────────────────────────┼───────────────┼─────────────────────┤
       │strcasecmp(), strncasecmp() │ Thread safety │ MT-Safe locale │
       ├──────────┼───────────────┼────────────────┤
       │strcoll() │ Thread safety │ MT-Safe locale │
       ├──────────────────────────┼───────────────┼─────────────────────┤
       │strerror()         │ Thread safety │ MT-Unsafe race:strerror │
       ├────────────┼───────────────┼────────────────┤
       │strfmon()   │ Thread safety │ MT-Safe locale │
       ├────────────┼──────────────────────────────────┼────────────────┤
       │            │ Thread safety                    │ MT-Safe locale │
       │strfromd(), ├──────────────────────────────────┼────────────────┤
       │strfromf(), │ Asynchronous signal safety       │ AS-Unsafe heap │
       │strfroml()  ├──────────────────────────────────┼────────────────┤
       │            │ Asynchronous cancellation safety │ AC-Unsafe mem  │
       ├───────────┼───────────────┼────────────────────┤
       │strftime() │ Thread safety │ MT-Safe env locale │
       ├───────────┼───────────────┼────────────────────┤
       │strptime() │ Thread safety │ MT-Safe env locale │
       ├───────────────┼───────────────┼─────────────────────────────────┤
       │strsignal()    │ Thread safety │ MT-Unsafe race:strsignal locale │
       ├─────────────┼───────────────┼────────────────┤
       │strcasestr() │ Thread safety │ MT-Safe locale │
       ├──────────────────────────────┼───────────────┼────────────────┤
       │strtod(), strtof(), strtold() │ Thread safety │ MT-Safe locale │
       ├─────────────────────────┼───────────────┼────────────────┤
       │strtoimax(), strtoumax() │ Thread safety │ MT-Safe locale │
       ├───────────┼───────────────┼───────────────────────┤
       │strtok()   │ Thread safety │ MT-Unsafe race:strtok │
       ├──────────────────────────────┼───────────────┼────────────────┤
       │strtol(), strtoll(), strtoq() │ Thread safety │ MT-Safe locale │
       ├─────────────────────────────────┼───────────────┼────────────────┤
       │strtoul(), strtoull(), strtouq() │ Thread safety │ MT-Safe locale │
       ├──────────┼───────────────┼────────────────┤
       │strxfrm() │ Thread safety │ MT-Safe locale │
       ├──────────┼───────────────┼─────────────┤
       │sysconf() │ Thread safety │ MT-Safe env │
       ├──────────────────────┼───────────────┼────────────────────┤
       │syslog(), vsyslog()   │ Thread safety │ MT-Safe env locale │
       ├──────────┼───────────────┼─────────────┤
       │tempnam() │ Thread safety │ MT-Safe env │
       ├──────────────────────┼───────────────┼────────────────────┤
       │timelocal(), timegm() │ Thread safety │ MT-Safe env locale │
       ├───────────┼───────────────┼──────────────────────────┤
       │tmpnam()   │ Thread safety │ MT-Unsafe race:tmpnam/!s │
       ├─────────────┼───────────────┼────────────────┤
       │towlower()   │ Thread safety │ MT-Safe locale │
       ├─────────────┼───────────────┼────────────────┤
       │towupper()   │ Thread safety │ MT-Safe locale │
       ├────────────────────┼───────────────┼────────────────────┤
       │tsearch(), tfind(), │ Thread safety │ MT-Safe race:rootp │
       │tdelete()           │               │                    │
       ├────────────────────┼───────────────┼────────────────────┤
       │twalk()             │ Thread safety │ MT-Safe race:root  │
       ├────────────────────┼───────────────┼────────────────────┤
       │twalk_r()           │ Thread safety │ MT-Safe race:root  │
       ├────────────┼───────────────┼────────────────────────┤
       │ttyname()   │ Thread safety │ MT-Unsafe race:ttyname │
       ├──────────┼───────────────┼───────────┤
       │ttyslot() │ Thread safety │ MT-Unsafe │
       ├──────────┼───────────────┼────────────────────┤
       │tzset()   │ Thread safety │ MT-Safe env locale │
       ├─────────────────────┼───────────────┼───────────────────────┤
       │getc_unlocked(),     │ Thread safety │ MT-Safe race:stream   │
       │putc_unlocked(),     │               │                       │
       │clearerr_unlocked(), │               │                       │
       │fflush_unlocked(),   │               │                       │
       │fgetc_unlocked(),    │               │                       │
       │fputc_unlocked(),    │               │                       │
       │fread_unlocked(),    │               │                       │
       │fwrite_unlocked(),   │               │                       │
       │fgets_unlocked(),    │               │                       │
       │fputs_unlocked(),    │               │                       │
       │getwc_unlocked(),    │               │                       │
       │fgetwc_unlocked(),   │               │                       │
       │fputwc_unlocked(),   │               │                       │
       │putwc_unlocked(),    │               │                       │
       │fgetws_unlocked(),   │               │                       │
       │fputws_unlocked()    │               │                       │
       ├─────────────────────┼───────────────┼───────────────────────┤
       │getchar_unlocked(),  │ Thread safety │ MT-Unsafe race:stdin  │
       │getwchar_unlocked()  │               │                       │
       ├─────────────────────┼───────────────┼───────────────────────┤
       │putchar_unlocked(),  │ Thread safety │ MT-Unsafe race:stdout │
       │putwchar_unlocked()  │               │                       │
       ├───────────┼───────────────┼──────────────────────────┤
       │updwtmp(), │ Thread safety │ MT-Unsafe sig:ALRM timer │
       │logwtmp()  │               │                          │
       ├──────────┼───────────────┼────────────────────────────┤
       │wcrtomb() │ Thread safety │ MT-Unsafe race:wcrtomb/!ps │
       ├─────────────┼───────────────┼────────────────┤
       │wcscasecmp() │ Thread safety │ MT-Safe locale │
       ├──────────────┼───────────────┼────────────────┤
       │wcsncasecmp() │ Thread safety │ MT-Safe locale │
       ├─────────────┼───────────────┼───────────────────────────────┤
       │wcsnrtombs() │ Thread safety │ MT-Unsafe race:wcsnrtombs/!ps │
       ├────────────┼───────────────┼──────────────────────────────┤
       │wcsrtombs() │ Thread safety │ MT-Unsafe race:wcsrtombs/!ps │
       ├─────────────────────────┼───────────────┼────────────────┤
       │wcstoimax(), wcstoumax() │ Thread safety │ MT-Safe locale │
       ├───────────┼───────────────┼────────────────┤
       │wcswidth() │ Thread safety │ MT-Safe locale │
       ├──────────┼───────────────┼────────────────┤
       │wctomb()  │ Thread safety │ MT-Unsafe race │
       ├──────────┼───────────────┼────────────────┤
       │wctrans() │ Thread safety │ MT-Safe locale │
       ├──────────┼───────────────┼────────────────┤
       │wctype()  │ Thread safety │ MT-Safe locale │
       ├──────────┼───────────────┼────────────────┤
       │wcwidth() │ Thread safety │ MT-Safe locale │
       ├───────────┼───────────────┼────────────────────────────────┤
       │wordexp()  │ Thread safety │ MT-Unsafe race:utent const:env │
       │           │               │ env sig:ALRM timer locale      │
       ├─────────────────────────┼───────────────┼────────────────┤
       │wprintf(), fwprintf(),   │ Thread safety │ MT-Safe locale │
       │swprintf(), vwprintf(),  │               │                │
       │vfwprintf(), vswprintf() │               │                │
       └─────────────────────────┴───────────────┴────────────────┘
