#!/usr/bin/perl

use warnings;
use strict;

use Data::Dumper qw(Dumper);
use IPC::Run3 qw(run3);

my $SRIOV_MANAGE = "/usr/lib/nvidia/sriov-manage";
my $DIR_SYS_DEVICES="/sys/bus/pci/devices";

if (! -e $SRIOV_MANAGE) {
    die "Error: missing $SRIOV_MANAGE\n";
}

sub get_bdf {
    my ($in, $out, $err);

    my @cmd = ("lspci");

    run3(\@cmd, \$in, \$out, \$err);

    my @pci = grep {/NVIDIA/} split /\n/,$out;
    for (0 .. scalar(@pci)-1) {
        $pci[$_]=($_+1).$pci[$_];
    }
    my $n = ask("Select a GPU\n",\@pci,"\n");

    my $bdf = $pci[$n-1];
    $bdf =~ s/.(.*?) .*NVIDIA.*/$1/;
    $bdf =~ tr/[:\.]/_/;

    return $bdf;
}

sub get_identifier {
    my $bdf = shift;

    my ($in, $out, $err);
    run3(["virsh","nodedev-list","--cap","pci"], \$in, \$out, \$err);
    die $err if $err;

    my ($identifier) = $out =~ /(^.*$bdf.*)/m;
    return $identifier;
}

sub dir_mdev {
    my $data2 = shift;
    my $dir = "$DIR_SYS_DEVICES/$data2/mdev_supported_types";

    my @dir_mdev;

    my ($dev_available, $dev_created) = 0;
    my $n = 1;
    opendir my $ls,$dir or die "$! $dir";
    my $max_name_length=12;
    while (my $current = readdir $ls) {
        next if $current =~ /^\./;
        open my $f_name,"<", "$dir/$current/name" or next;
        my $name = <$f_name>;
        chomp $name;
        close $f_name;
        $name =~ s/^GRID //;
        open $f_name,"<","$dir/$current/description" or next;
        my $description = <$f_name>;
        chomp $description;
        close $f_name;

        open $f_name,"<","$dir/$current/available_instances" or die $!;
        my $available = <$f_name>;
        chomp $available;
        close $f_name;

        $description =~ s/framebuffer=/fb=/;
        $description =~ s/max_resolution=/max_res=/;
        $description =~ s/num_heads/h/;
        $description =~ s/frl_config/frl/;
        $description =~ s{max_instance=(\d)}{available=$available/$1};
        my $created=$available-$1;
        $dev_created += $created;

        my $s0= '';
        $s0 = " " if $n<10;
        my $s1 = '';
        $s1 = " " if length($current)<10;
        my $s2 = ' ';
        $s2 .= " " if length($name)<$max_name_length;
        print "[$s0$n] $current$s1 $name:$s2$description\n";
        push @dir_mdev,([$current, $available, $created]);
        $n++;
        $dev_available += $available;
    }
    closedir $ls;
    return (undef, $dev_available, $dev_created) if !$dev_available;
    my $choose = choose($n-1);
    die "Error: no $choose in ".Dumper(\@dir_mdev) if !$dir_mdev[$choose-1];
    return @{$dir_mdev[$choose-1]};
}

sub choose {
    my ($max, $default) = @_;
    for (;;) {
        print "choose one: ";
        my $choose = <STDIN>;
        chomp $choose;
        return $default if !$choose && $default;
        return $choose if $choose =~ /^\d+$/ && $choose >0 && $choose <=$max;
        print "Wrong choice, please choose betweeen 1 and $max\n";
    }
}

sub get_data {
    my $identifier = shift;
    my ($in, $out, $err);
    run3(["virsh","nodedev-dumpxml",$identifier], \$in, \$out, \$err);

    my ($domain, $bus, $slot, $function) = $out
    =~ /domain='0x(.*?)'.*bus='0x(.*?)'.*slot='0x(.*?)' function='0x(.*?)'/;

    die "Error: no domain found in '$out'" if !$domain;

    #    warn "domain=$domain bus=$bus slot=$slot function=$function\n";
    my $data = "$slot:$bus:$domain.$function";
    my $data2 = "$domain:$bus:$slot.$function";

    return ($data, $data2);
}

sub enable_virt {
    my $data = shift;
    my ($in, $out, $err);
    print "$SRIOV_MANAGE -e $data\n";
    run3([$SRIOV_MANAGE,"-e",$data],\$in, \$out, \$err);
    die "$SRIOV_MANAGE -e $data\n".$err if $err;
}

sub mdev_already {
    my ($data, $dir_mdev) = @_;

    my ($in, $out, $err);

    my @cmd = ("mdevctl","list","-d");
    run3(\@cmd, \$in, \$out, \$err);
    my ($uuid) = $out =~ m/^(.*) $data $dir_mdev/m;
    return ($uuid, "defined") if $uuid;

    @cmd = ("mdevctl","list");
    run3(\@cmd, \$in, \$out, \$err);
    ($uuid) = $out =~ m/^(.*) $data $dir_mdev/m;

    return ($uuid or undef);

}


sub create_mdev {
    my ($data2,$dir_mdev, $available) = @_;
    my $n = 1;
    if ($available>1) {
        for (;;) {
            print "How many devices do you want to create ?"
            ."[1-$available]\n";
            $n=<STDIN>;
            last if $n && $n =~ /^\d+/ && $n>0 && $n<=$available;
        }
    }

    my $dir = "$DIR_SYS_DEVICES/$data2/mdev_supported_types";
    $dir_mdev = "$dir/$dir_mdev";

    my @uuid;
    for ( 1 .. $n) {
        my $uuid = `uuidgen`;
        chomp $uuid;
        my $file_create = "$dir_mdev/create";
        open my $out ,">", $file_create or die "$! $file_create";
        print $out $uuid;
        close $out or die "$! $file_create";
        push @uuid,($uuid);
        start_mdev($uuid);
    }

    return @uuid;
}

sub ask {
    my $message = shift;
    my $options = shift;
    my $join = (shift or ', ');
    my %option;
    for (@$options) {
        my ($i, $text) = /(.)(.*)/;
        $option{$i}=$text;
    }
    for (;;) {
        print "$message".join($join, map { "$_: $option{$_}" } sort keys %option);
        print "\n";
        my $what = <STDIN>;
        chomp $what;
        return 0 if exists $option{0} && !$what;
        return $what if exists $option{$what};
    }
}

sub start_mdev {
    my $uuid = shift;

    my ($in, $out, $err);

    my @cmd = ("mdevctl","start","--uuid",$uuid);
    run3(\@cmd, \$in, \$out, \$err);

    print "Starting device uuid = $uuid\n";
}

sub stop_mdev {
    my $data = shift;
    my ($in, $out, $err);

    my @cmd = ("mdevctl","list","--parent",$data);
    run3(\@cmd, \$in, \$out, \$err);

    for my $line ( split /\n/, $out ) {
        my ($uuid) = $line =~ /^(.*?) /;
        @cmd = ("mdevctl","stop","--uuid",$uuid);
        my ($in2, $out2, $err2);
        run3(\@cmd, \$in2, \$out2, \$err2);
        die "@cmd\n$err2" if $err2;
        print "Stopping $uuid\n";
    }

}

sub mdevctl {
    my ($option, $uuid) = @_;

    my @cmd =(
        ["mdevctl","start","--uuid",$uuid]
        ,["mdevctl","stop","--uuid",$uuid]
        ,["mdevctl","undefine","--uuid",$uuid]
    );
    my ($in, $out, $err);
    run3($cmd[$option-1], \$in, \$out, \$err);
    die join(" ",@{$cmd[$option-1]})."\n$err" if $err;
    print $out if $out;
}

###################################################################

die "Error: $0 must run as root\n" if $>;
my $bdf = get_bdf();
my $identifier = get_identifier($bdf);
my ($data1, $data2) = get_data($identifier);
enable_virt($data1);

my ($dir_mdev, $available, $created) = dir_mdev($data2);;
my @options = qw(0Nothing);
push @options,("1Create") if $available;
push @options,("2Stop")     if $created;

print "No devices available\n"
    if !$available;

my $option = ask("What should I do with device ? ", \@options);
if ($option == 1 ) {
    create_mdev($data2, $dir_mdev, $available);
} elsif ($option == 2) {
    stop_mdev($data2);
}

