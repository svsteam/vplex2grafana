#!/usr/bin/perl 
use strict ;
use REST::Client;
use JSON::PP;
use Data::Dumper::Names;
use Time::Local ;
use IO::Socket::INET;

#use Time::HiRes 
# copyright GPL 3.0
# 

# start this via cron (e.g. once every 10 minutes for each vplex with the boxname as argument
#configuration parameters
#my $VPLEX_IP = '10.247.87.150';
my %vplexip=('BOX1NAME'=>'10.1.2.3' , 'BOX2NAME' => '10.1.2.4');
my %altips=();

my $vplexbox=$ARGV[0];
die "vplex2grafana box" unless defined $vplexbox;

my $VPLEX_IP = $vplexip{$vplexbox};
my $altip=$altips{$vplexbox};

die "unkown vplex  box $vplexbox " unless defined $VPLEX_IP;
my $VPLEX_PORT = '443';
my $VPLEX_ADMIN_USER = 'vplex-admin-user-name';
my $VPLEX_ADMIN_PASS = 'vplex-admin-user-password-goes-here';
#end configuration parameters
my $volgroup;
my $volbox;

my $volmon='VIRTUAL_VOLUMES_PERPETUAL_MONITOR';
my $sysmon='PERPETUAL_vplex_sys_perf_mon_v21';
my @volmons;
my @sysmons;

my $carbon_server = '10.11.22.33';
my $carbon_port = 8086;
my $prefix='storage.vplex';

my $sock = IO::Socket::INET->new(
        PeerAddr => $carbon_server,
        PeerPort => $carbon_port,
        Proto    => 'tcp'
);
                        
die "Unable to connect: $!\n" unless ($sock->connected);
print "connected to carbon\n";                        

sub  unfucku {
  my $str=shift;
  $str =~ s/u\'/\'/g ;
  return $str;
}



$ENV{'PERL_LWP_SSL_VERIFY_HOSTNAME'} = 0; 
my $client = REST::Client->new();
#my $json = JSON::PP->new->pretty;

my $host = "https://".$VPLEX_IP.":".$VPLEX_PORT;
$client->setHost($host);
$client->addHeader('Username',$VPLEX_ADMIN_USER);
$client->addHeader('Password',$VPLEX_ADMIN_PASS);
#$client->addHeader('Accept','application/json;format=1;prettyprint=1');

#$client->GET('vplex/cluster-contexts');
#$client->GET('vplex/engines');

sub svget {
  open(S,"<storageviews.txt") or die "$!";
  while(<S>) {
    chomp;
    my @a=split("\t");
    my $vol=$a[2];
    my $box=$a[0];
    my $grp=$a[1];
    
    #if (defined $volgroup->{$box}->{$vol}) {
      # print "volume $vol on box $box in group $grp is also in group: ",$volgroup->{$box}->{$vol},"\n";
    #}
    $volgroup->{$vol}->{$grp}=$box;
  }
  close(S);
}

sub monget {
  print "getting monitor data\n";
  my  $t=time();
  $client->GET('vplex/monitoring/directors/*/monitors/');
  my $rc=$client->responseCode ();
  print "get monitors rc=$rc time=",time()-$t,"\n";
  my $resp=$client->responseContent();
  
  my $moniref=decode_json $resp;
  if (defined $moniref->{'response'} ) {
    my $monis=$moniref->{'response'}->{'context'};
    for(my $i=0; $i <= $#{$monis} ; $i++) {
      my $monii=$monis->[$i];
      my $parent=$monii->{'parent'};
      my $child=$monii->{'children'};
      # print " $i $parent ",Dumper($child),"\n";
      for(my $j=0 ; $j <= $#{$child} ; $j++) {
        my $c=$child->[$j];
        if ($c->{'type'} eq 'monitor' ) {
          my $mo=$c->{'name'};
          if ($mo =~ m /^dir/ and $mo =~ /$volmon/ ) {
            #print " $i found volume monitor $parent $mo\n";
            push @volmons,$mo
          }  
          if ($mo =~ m /^dir/ and $mo =~ /$sysmon/ ) {
            #print " $i found system monitor $parent $mo\n";
            push @sysmons,$mo
          }  
        }
      }
    }
  }
}

# konvert utc timestamp to sec since epoch in utc
sub ts2sec {
  my $time=shift;
  my $res;
  if ($time =~  m/^(\d+)-(\d+)-(\d+) (\d+):(\d+):(\d+)$/ ) {
    $res= timegm( $6, $5, $4, $3, ($2)-1, $1 );
  }
  return $res;
}


# 'timestamp' => '2016-10-11 10:56:54',
# 'stats' => [
#   {
#       'fe-lu read-lat recent-average (us)' => '31',
#       'fe-lu ops (counts/s)' => '0.0167',
#       'VPD Id' => 'VPD83T3:6000144000000010703c9d9bd6dc3a24',
#       'Virtual Volume' => 'dev_TEMP_vol0001_vol',
#       'fe-lu write (KB/s)' => '0',
#       'fe-lu read (KB/s)' => '0.00833',
#       'fe-lu write-lat recent-average (us)' => '0'

my $sysmap={
  'KB/s' => 'kb',
  'counts/s' => 'ops',
  '%' => 'percent',
  'us' => 'us',
  'counts' => 'counts' 
};

 
my $femap={
  'fe-lu read-lat recent-average (us)'  => 'read_lat_us',
  'fe-lu ops (counts/s)'                => 'ops',
  'fe-lu write (KB/s)'                  => 'write_kb',
  'fe-lu read (KB/s)'                   => 'read_kb',
  'fe-lu write-lat recent-average (us)' => 'write_lat_us'
};              

my $fediv={
  'read_lat_us' => 1 ,
  'write_lat_us' => 1
};              

my @fekeys=();
foreach my $k (keys %$femap) {
  push @fekeys,$femap->{$k};
}
foreach my $k (keys %$fediv) {
  push @fekeys,$k ."_max";
}
# print "fekeys=",join(',',@fekeys),"\n";

sub feadd {
  my $sumref=shift;
  my $sourceref=shift;
  while( (my $k, my $trans) = each %$femap) {
    # my $trans=$femap->{$k};
    my $src=$sourceref->{$k};
    $sumref->{$trans} += $src ;
    if (defined $fediv->{$trans}) {
      if (defined $sumref->{$trans ."_max" } ) {
        if ($src > $sumref->{$trans ."_max" } ) {
          $sumref->{$trans ."_max" }=$src;
        }
      } else {
        $sumref->{$trans ."_max" }=$src;
      }
    }
  }
  $sumref->{'n'} += 1; 
}

sub fefeed {
  my $sock=shift;
  my $ref=shift;
  my $pfix=shift;
  
  my $ts=$ref->{'ts'};
  die "timestamp not defined for $pfix " unless defined $ts;
  foreach my $trans (@fekeys) {
    my $val=$ref->{$trans};
    if (defined $fediv->{$trans}) {
      $val=$val / $ref->{'n'};
    }
    my $str="$pfix.$trans $val $ts";
    # print "$str\n";
    print $sock "$str\n";
  }
}

sub dirfeed {
  my $sock=shift;
  my $ref=shift;
  my $pfix=shift;
  my $ts=$ref->{'Time'};
  $ts=ts2sec($ts);
  while( (my $k, my $val) = each (%$ref)) {
    if ($k ne 'Time' and defined $val and $val ne 'no data' and $val ne '') {
      my $str; 
      if ($k =~ m/^([^\s\.]*)\.([^\s]*)\s\((.*)\)$/ ) {
        my $ext=$sysmap->{$3};
        $ext='x' unless defined $ext;
        $str="$pfix.$1.$2_$ext";
        # print $sock "$str $val $ts\n";
      } elsif ($k =~ m/^([^\s\.]*)\.([^\s]*)\s([^\s]+)\s\((.*)\)$/ ) {
        my $ext=$sysmap->{$4};
        $ext='x' unless defined $ext;
        $str="$pfix.$1.$3.$2_$ext";
      } else {
        print "error parsing key \'$k\'\n";
      }
      # print "$str $val $ts\n";
      print $sock "$str $val $ts\n";
    } 
  }
  
}


my $groupsum;
my $dirsum;


sub getvolstats {
   my $vmon=shift;
   my $json=JSON::PP->new->utf8;
   my $t=0;
   $t=time();
   $client->POST('vplex/monitor+get-stats','{ "args": "--monitors=$vmon" }');
   my $resp = $client->responseContent();
   my $rc=$client->responseCode ();
   print "get time: $vmon ",time()-$t,"  rc=$rc\n"; 
   if ($rc eq 200 ) {
     $json=$json->allow_singlequote();
     $t=time();
     my $jref=$json->decode($resp);
     print "parse time: ",time()-$t,"\n";
     if (defined $resp and defined  $jref->{'response'} ) {
      
       my $data=$jref->{'response'}->{'custom-data'}; #->{$vmon};
       # print "dat=$data\n";
       $t=time();
       $data=unfucku($data);
       my $jdata=$json->decode($data);
       print "parse2 time: ",time()-$t,"\n";
       if (defined $jdata->{"$vmon"}) {
          my $vdata=$jdata->{"$vmon"};
          if ($vdata ne 'no data') {
            my $tmg=$vdata->{'timestamp'};
            my $ts=ts2sec($tmg);
            print "$tmg $ts\n";
            my $stats=$vdata->{'stats'};
            my $director=$vmon;
            $director =~ s/\_.*//;
            $dirsum->{$director}->{'ts'}=$ts;
            for(my $i=0; $i <= $#{$stats}; $i++) {
              my $volstat=$stats->[$i];
              my $vv=$volstat->{'Virtual Volume'};
              
              my @grps=keys(  %{$volgroup->{$vv}} );
              # print "  $director $vmon $vv (",join(",",@grps),")\n";
              feadd($dirsum->{$director},$volstat);
              foreach my $gg (@grps) {
                $groupsum->{$gg}->{'ts'}=$ts;
                feadd($groupsum->{$gg},$volstat);
              }
              #x ## continue here also add to each group
              # print Dumper($volgroup->{$vv});
            }  
          }
          # print Dumper($vdata);
       } else {
         print "$vmon not defined\n";
       }
     }
   }  
   #print Dumper($jref);
   # print $response;
}

sub getsysstats {
   my $smon=shift;
   my $json=JSON::PP->new->utf8;
   my $t=0;
   $t=time();
   $client->POST('vplex/monitor+get-stats','{ "args": "--monitors=$smon" }');
   my $rc=$client->responseCode();
   print "get time: $smon ",time()-$t,"  rc=$rc\n"; 
   if ($rc eq 200 ) {
     my $sresp = $client->responseContent();

     # print "=" x 40,"\n",$sresp,"=" x 40,"\n";
     $json=$json->allow_singlequote();
     $t=time();
     my $jref=$json->decode($sresp);
     print "parse time: ",time()-$t,"\n";
     if (defined $sresp and defined  $jref->{'response'} ) {
       # print "jref defined for $smon\n";
       my $data=$jref->{'response'}->{'custom-data'}; #->{$vmon};
       $t=time();
       my $jdata=$json->decode($data);
       print "parse2 time: ",time()-$t," $smon\n";
       if (defined $jdata->{"$smon"}) {
         my $sm=$jdata->{"$smon"};
         my $director=$smon;
         $director =~ s/\_.*//;
         dirfeed($sock,$sm,"$prefix.$vplexbox.dir.$director");               
         # print "-" x 40, " $smon \n";
         # print Dumper($sm);
         #print "\n\n";
       }  
     }
   }  
   #print Dumper($jref);
   # print $response;
}



svget();
monget();
#exit(0);

foreach my $vmon (@volmons) {
  getvolstats($vmon);
}

foreach my $sysmon (@sysmons) {
  getsysstats($sysmon);
}

while( (my $dir, my $ref) = each (%$dirsum)) {
  # print "dir=$dir, ",$ref->{'read_kb'}," ",$ref->{'ts'},"\n"; 
  fefeed($sock,$ref,"$prefix.$vplexbox.aggr.$dir");
} 

while( (my $vg, my $ref) = each (%$groupsum)) {
  # print "vg=$vg, ",$ref->{'read_kb'}," ",$ref->{'ts'},"\n"; 
  fefeed($sock,$ref,"$prefix.$vplexbox.volumegroup.$vg");
} 
  
#foreach my $smon (@sysmons) {
#  getsysstats($smon);
#}  
  

#$client->POST('vplex/monitor+get-stats','{ "args": "--monitors=director-2-1-A_VIRTUAL_VOLUMES_PERPETUAL_MONITOR" }');

  

