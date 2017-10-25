#!/usr/bin/perl
use strict ;
use REST::Client;
use JSON::PP;
use Data::Dumper::Names;
use Time::Local ;

my %vplexip=('BOX1NAME'=>'10.1.2.3' , 'BOX2NAME' => '10.1.2.4');
my $vplexbox=$ARGV[0];
die "vplexgetstoraveviews-new box" unless defined $vplexbox;

my $VPLEX_IP = $vplexip{$vplexbox};

#configuration parameters
# my $VPLEX_IP = '10.247.87.151';
my $VPLEX_PORT = '443';
my $VPLEX_ADMIN_USER = 'vplex-admin-user-name';
my $VPLEX_ADMIN_PASS = 'vplex-admin-user-password-goes-here';
#end configuration parameters

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
  open(O,">storage-volumes-" . $vplexbox .".txt" ) or die "$!";
  my  $t=time();
  $client->GET('vplex/clusters/*/exports/storage-views/');
  my $response = $client->responseContent();
  print "get storage views, took ",time()-$t,"seconds\n";
  #print $response;
  my $sv  = decode_json $response;
  if (defined $sv->{'response'}->{'context'}) {
    my $aref=$sv->{'response'}->{'context'};
    for(my $i=0; $i <= $#{$aref} ; $i++) {
      # print "$i ","=" x 20,"\n",Dumper($aref->[$i]),"\n";
      my @parent=split('/',$aref->[$i]->{'parent'});
      my $child=$aref->[$i]->{'children'};
      my $box=$parent[2];
      for(my $j=0; $j <= $#{$child}; $j++) {
        if ($child->[$j]->{'type'} eq 'storage-view') {
          my $sv=$child->[$j]->{'name'};
          print " $box $sv\n"; 
          $t=time();
          $client->GET("vplex/clusters/$box/exports/storage-views/$sv");
          print "get clusters on $box, took ",time()-$t,"seconds\n";
          my $resp = $client->responseContent();
          my $svclient=decode_json $resp ;
          # print $resp,"\n";
          # print "dump: ",Dumper($svclient),"\n";
          my $sva=$svclient->{'response'}->{'context'}->[0]->{'attributes'};
          if (defined $sva) {
            for (my $k=0; $k <= $#{$sva} ; $k++) {
              my $svaa=$sva->[$k];
              if ( $svaa->{'name'} eq 'virtual-volumes' ) {
                my $vvs=$svaa->{'value'};
                for(my $l=0 ; $l <= $#{$vvs} ; $l++) {
                  my $str=$vvs->[$l];
                  my @vvsa=split(',',$str);
                  my $vvname=$vvsa[1];
                  # print "  $box $sv $vvname\n";
                  print O join("\t",$box,$sv,$vvname),"\n";
                }
              }
            }
          }
          sleep(5);
        } else {
          print "unkown type: ",$child->[$j]->{'type'},"\n";
        }  
      }
    }
  }
  close(O);
}

svget();
  

