#!/usr/bin/perl -w
#=====================================================================
#
# 	FILE:			Rpm.pl
#
#	USAGE:			perl rpm.pl <command>
#
#	DESCRIPTION:	This script is designed to monitor the reports on the RPM console.  It can send periodic
# 					emails with the status of the reports including run time, and also warning emails if a 
# 					report runs for an unusually long time.
#
#	OPTIONS:		?
#	REQUIREMENTS:	?
#
#	NOTES:			
#	AUTHOR:			Louis Amstutz
#	COMPANY:  		CMAH
#	VERSION:		1.0
#	CREATED:		04/01/2011
#	REVISION:		05/19/2011
#=====================================================================


use strict;
use warnings;
use LWP::UserAgent;
use HTML::TokeParser;
use HTTP::Cookies;
use DBI;
use Net::SMTP;
use XML::Simple;
use Storable;



######################### initialization ##############################

my $logfile = "../logs/Rpm.log";
my $configfile = "../config/Rpm.config";
my $cookiesFile = "../config/cookie.lwp";
my $reportsFile = "../config/reports.dat";

my $xml = new XML::Simple;
my $data = $xml->XMLin($configfile);

my $user = $data->{login}->{user};
my $pass = $data->{login}->{pass};
my $rpmurl = $data->{urls}->{main};
my $overviewurl = $data->{urls}->{overview};
my $batchSummaryurl = $data->{urls}->{batch};
my $reporturl = $data->{urls}->{report};
my %sysURLs;
$sysURLs{"bdsprod"} = $data->{urls}->{bdsprod};
$sysURLs{"smsprod"} = $data->{urls}->{smsprod};
$sysURLs{"bds12"} = $data->{urls}->{bds12};
$sysURLs{"sms12"} = $data->{urls}->{sms12};
$sysURLs{"bds13"} = $data->{urls}->{bds13};
$sysURLs{"sms13"} = $data->{urls}->{sms13};

my $maxPages = $data->{limits}->{maxPages};
my $rpmSessionTimeout = $data->{limits}->{rpmSessionTimeout};
my $tooLongReportTime = $data->{limits}->{reportWarningTime};
my $mailServer = $data->{urls}->{mailserver};
my $mailRecipient = $data->{urls}->{mailRecipient};

my @systemsToMonitor;
foreach (@{$data->{systemsToMonitor}->{system}}) {
	push(@systemsToMonitor, $_);
}

my $log;
open($log, ">>", $logfile) or warn "Failed to open log file\n";



######################### subroutines ##############################

sub logit {
	my ($file, $message) = @_;
	
	my ($sec,$min,$hour,$mday,$mon,$year,$wday,$yday,$isdst) = localtime(time);
	$year += 1900;
	my $text = sprintf "%04d/%02d/%02d %02d:%02d - $message\n", $year, $mon, $mday, $hour, $min;
	
	print $message . "\n";
	print $file $text;
}

##############################################################################
# Find some text in an html document and advance the stream to that point
#
# $stream 	- An HTML::TokeParser with the html data
# $starttag - The tag before the text
# $text 	- The text to search for
##############################################################################
sub find_text {
  my($stream, $starttag, $text) = @_;
  
  my $found = 0;
  while (!$found) {
    my $tag = $stream->get_tag($starttag);
    my $testtext = $stream->get_text();
    if (!$tag || $testtext eq $text) {
      $found = 1;
    }
  }
}

##############################################################################
# Find a tag with a certain CSS class in an html document and advance the 
# stream to that point
#
# $stream 	- An HTML::TokeParser with the html data
# $starttag - The tag before the text
# $class 	- The CSS class to search for
##############################################################################
sub find_class {
  my($stream, $starttag, $class) = @_;
  #print $starttag . "<>" . $class . " ";
  my $found = 0;
  while (!$found) {
    my $tag = $stream->get_tag($starttag);
    if (!$tag || ($tag->[1]{class} && $tag->[1]{class} eq $class)) {
      $found = 1;
    }

  }
}
	
##############################################################################
# Get a page of the RPM console and return it.  The parameters determine which 
# page to get.  Note that the LWP::UserAgent must have a valid, non-expired
# session cookie (it must be logged in already) or this will fail.
#
# $agent 		- An LWP::UserAgent that will be used to get the page
# $system		- Which system (bdsprod, smsprod, bds12, etc.)
# $pagesBack	- Page number to get (1 is current, higher numbers are older)
# $submitted, $completed, $aborted, $running, $deleted - Values of checkboxes
#
# return		- The HTML response object
##############################################################################
sub getRpmPage {
	my($agent, $system, $reportsOrBatch, $pagesBack, $submitted, $completed, $aborted, $running, $deleted) = @_;

	my $typeurl;
	if ($reportsOrBatch eq "report") {$typeurl = $reporturl;}
	elsif ($reportsOrBatch eq "batch") {$typeurl = $batchSummaryurl;}
	else {
		logit($log, "Invalid type parameter");
		die;
	}

	my @parameters = ('pageNo' => $pagesBack);
	
	if ($submitted == 1) {push(@parameters, "scheduled" => "on");}
	if ($completed == 1) {push(@parameters, "completed" => "on");}
	if ($aborted == 1) {push(@parameters, "aborted" => "on");}
	if ($running == 1) {push(@parameters, "running" => "on");}
	if ($deleted == 1) {push(@parameters, "deleted" => "on");}
	
	my $url = $sysURLs{$system} . $rpmurl . $typeurl;
	my $response = $agent->post($url, \@parameters);

	return $response;
}

##############################################################################
# Login to the RPM console and add the session cookie to the LWP::UserAgent's
# cookie jar.  Save the cookie jar to disk.
#
# $agent 		- An LWP::UserAgent that will be used to login
# $system		- Which system (bdsprod, smsprod, bds12, etc.)
##############################################################################
sub loginRpm {
	my($agent, $system) = @_;
	
	my $url = $sysURLs{$system} . $rpmurl . $overviewurl;
	my @parameters = (
		'Username' => $user,
		'Password' => $pass
	);
	my $response = $agent->post($url, \@parameters);
	my $cookie_jar = $agent->cookie_jar();
	$cookie_jar->save;
}

##############################################################################
# Parse the HTML, generate a list of reports, and return it.
#
# $text 		- The HTML to parse
#
# return		- An array containing all the reports on the page.  Each report
#				  is represented by a hashtable.
##############################################################################
sub parseReports {
	my($text) = @_;
	
	if ($text =~ m/Error 500/) {print "Error 500\n";}
	
	my $stream = HTML::TokeParser->new(\$text);
	if (!$stream) {
		logit($log, "Failed to load HTML Parser.");
	}

	my @reportList;
	
	my $classTag = "TableRowEven";
	my $eof = 0;
	while (!$eof) {		
		find_class($stream, "td", $classTag);
		my $id = $stream->get_text();
		find_class($stream, "td", $classTag);
		my $name = $stream->get_text();	
		find_class($stream, "td", $classTag);
		my $tag = $stream->get_tag("input");
		my $priority = $tag->[1]{value};
		find_class($stream, "td", $classTag);
		$tag = $stream->get_tag("input");
		my $slevel = $tag->[1]{value};	
		find_class($stream, "td", $classTag);
		my $status = $stream->get_text();	
		find_class($stream, "td", $classTag);
		my $user = $stream->get_text();	
		find_class($stream, "td", $classTag);
		my $startdate = $stream->get_text();	
		find_class($stream, "td", $classTag);
		my $enddate = $stream->get_text();	
		find_class($stream, "td", $classTag);
		my $errors = $stream->get_text();	
		find_class($stream, "td", $classTag);
		my $stop = $stream->get_text();	
		
		if (!$id) {$eof = 1;}
		else {
			if ($classTag eq "TableRowEven") {$classTag = "TableRowOdd";}
			elsif ($classTag eq "TableRowOdd") {$classTag = "TableRowEven";}
			
			push(@reportList, {
				"rid" => $id,
				"rname" => $name,
				"priority" => $priority,
				"slevel" => $slevel,
				"status" => $status,
				"user" => $user,
				"startdate" => $startdate,
				"enddate" => $enddate,
				"errors" => $errors,
				"starttime" => -1
			});
			#print ">>" . $id . "-" . $name . "-" . $priority . "-" . $slevel . "-" . $status . "-" . $user . "-" . $startdate . "-" . $enddate . "-" . $errors . "<<\n";
		}
	}
	return \@reportList;
}

##############################################################################
# Update the list of active reports for specific systems
#
# $systemsToUpdate		- Which systems to update (bdsprod, smsprod, bds12, etc.)
##############################################################################
sub updateReports {
	my ($systemsToUpdate) = @_;

	my $agent = LWP::UserAgent->new();
	my $cookie_jar = HTTP::Cookies->new(
		file => $cookiesFile,
		ignore_discard => 1
	);
	$agent->cookie_jar($cookie_jar);  
	
	my $activeReports;
	if (-e $reportsFile) {#TODO: Check if the reports file is valid
		$activeReports = retrieve($reportsFile);
	}
	else {
		$activeReports = {};
	}

	foreach (@$systemsToUpdate) {
		my $system = $_;
		if (!$activeReports->{$system}) {$activeReports->{$system} = [];}
		
		my @newReportList;
		my $lastReportId = 99999999;
		my $failureCount = 0;
		
		if ( !(-e $cookiesFile) || ( (time - (stat($cookiesFile))[8]) > $rpmSessionTimeout)) { #TODO: check timestamps of cookies here
			loginRpm($agent, $system);
		}
		
		#This loop gets all the running reports and puts them in the array @newReportList
		for (my $i=1; $i<=$maxPages; $i++) {
			
			my $succeeded = 0;
			my $response;
			while (!$succeeded) {
				$response = getRpmPage($agent, $system, "report", $i, 1,0,0,1,0);
				if ($response->is_success) {$succeeded = 1;}
				else {
					logit ($log, $response->status_line . " retrying\n");
					if ($failureCount > 4) {
						logit ($log, "Htttp Error -- ", $response->status_line);
						die;
					}
					loginRpm($agent, $system); #if we failed to get the page, try logging in again
					$failureCount++;
				}
			}

			if (!$response->content_type eq 'text/html') {
				logit ($log, "Expecting HTML, not ", $response->content_type);
				die ;
			}

			my $html = $response->decoded_content;
			my $pageReportList = parseReports($html);
			my $pageRLen =  @$pageReportList;
			
			#Check if this is the last page (if there's a next button)
			my $isLastPage;
			if ($html =~ m/Next >>/) {$isLastPage = 0;}
			else {$isLastPage = 1;}
			
			#Add everything from pageReportList to newReportList
			for (my $j=0; $j<$pageRLen; $j++) { 
				my $report = $pageReportList->[$j];
				if ($report->{"rid"} < $lastReportId) {push(@newReportList, $report);}
			}
			if ($pageRLen > 0) {
				my $lastReport = $pageReportList->[$pageRLen-1];
				$lastReportId = $lastReport->{"rid"};
			}
			last if ($isLastPage == 1);
		}
		
		my $activeReportsOnSys = $activeReports->{$system};

		#Update the start time of all reports
		foreach (@newReportList) {
			my $report = $_;
			
			if ($report->{"status"} eq "Submitted") {
				$report->{"starttime"} = -1;
			}
			else {
				my $rIndex = searchReports($activeReportsOnSys  , $report->{"rid"});
				#A start time of -1 means the report hasn't started running it (it's in submitted status)
				if ( $rIndex != -1 && $activeReportsOnSys->[$rIndex]->{"starttime"} != -1) {
					$report->{"starttime"} = $activeReportsOnSys->[$rIndex]->{"starttime"};
				}
				else {
					$report->{"starttime"} = time;
				}
			}
			#print ">" . $report->{"rid"} . " " . $report->{"rname"} . " " . $report->{"starttime"} . "\n";
		}
		$activeReports->{$system} = \@newReportList;
	}
	store $activeReports, $reportsFile;
}

##############################################################################
# Search a list of reports for one with a specific ID
#
# $reList	- The list of reports
# $id		- The report ID to search for
#
# return	- If the report is found, return the index in the list.
#			  Otherwise, return -1
##############################################################################
sub searchReports {
	my($reList, $id) = @_;

	my $resultIndex = -1;
	my $len =  @$reList;
	for (my $i=0; $i<$len; $i++) {
		my $report = $reList->[$i];
		if ($report->{"rid"} eq $id) {
			$resultIndex = $i;
			last;
		}
	}
	return $resultIndex;
}

sub sendReportStatusEmail {
	my ($messageType) = @_;
	
	if (-e $reportsFile) {
		my @timeNow = localtime(time);
		my ($mm,$h,$d,$m,$y) = (localtime(time))[1,2,3,4,5];
		my $emailString;
		my $emailSubject;
		if ($messageType eq "status") {
			$emailString = sprintf 'Reports currently running at %02d:%02d %d/%d/%d', $h, $mm, $m+1, $d, $y+1900;
			$emailSubject = "Running Reports";
		}
		else {
			$emailString = "The following reports have exceeded " . ($tooLongReportTime/60/60) . " hours.";
			$emailSubject = "WARNING: Report has exceeded " . ($tooLongReportTime/60/60) . " hours";
		}
		
		my $longReportCount = 0;
		my $activeReports = retrieve($reportsFile);
		foreach my $system (keys %$activeReports) {
			#print $system . " " . $activeReports->{$system};
			$emailString = $emailString . "<br/><h3>" . $system . "</h3>\n";
			my $len = @{$activeReports->{$system}};

			if ($len == 0) {
				$emailString = $emailString . "None<br/>";
			}
			else {
				if ($messageType eq "status") {
					$emailString = $emailString . "Total (submitted + running): " . $len . "<br/>\n";
				}
				$emailString = $emailString . "<table border=1><tr><th>ID</th><th>Priority</th><th>Name</th><th>Approx Runtime</th><th>Status</th></tr>\n";
				
				foreach (@{$activeReports->{$system}}) {
					my $report = $_;
					if ($report->{"status"} ne "Submitted") {
						my $duration = time - $report->{"starttime"};
						my $text = "<tr><td>" . $report->{"rid"} . "</td><td>" . $report->{"priority"} . "</td><td>" . $report->{"rname"} . 
							"</td><td>" . formatTimeSpan($duration) . "</td><td>" . $report->{"status"} . "</td></tr>\n";
						if ($duration > $tooLongReportTime || $messageType eq "status") {
							$emailString = $emailString . $text;
						}
						if ($duration > $tooLongReportTime) {$longReportCount += 1;}
					}
					
				}
				
				$emailString = $emailString . "</table>\n";
			}
		}
		
		if ($longReportCount > 0 || $messageType eq "status") {
			sendEmail($mailRecipient, $emailSubject, $emailString);
			logit ($log,"Sent " . $messageType . " email");
		}
	}
}

##############################################################################
# Send an email in HTML format
#
# $recipient	- The email recipient
# $subject		- The subject of the email
# $body			- The body of the email
##############################################################################
sub sendEmail {
	my ($recipient, $subject, $body) = @_;
	
	my $smtp = Net::SMTP->new('EXCMAH.cmamdm.enterprise.corp');
	$smtp->mail( 'perl@autosend.com' );

	$smtp->to($recipient);        				

	$smtp->data();

	$smtp->datasend("To:" . $recipient . "\n");
	$smtp->datasend("Subject:" . $subject . "\n");
	$smtp->datasend("MIME-Version: 1.0\n");
	$smtp->datasend("Content-Type: text/html\n");

	$smtp->datasend($body);
	$smtp->dataend(); 
	
	$smtp->quit;
}

##############################################################################
# Takes a time span parameter and formats it in hours, minutes, and seconds
#
# $seconds		- The total number of seconds
# 
# return		- A string in the format HH:MM:SS
##############################################################################
sub formatTimeSpan {
	my ($seconds) = @_;
	
	my $hours = int($seconds / 3600);
	my $minutes = int($seconds / 60 % 60);
	$seconds = $seconds % 60;
	
	my $timeString = $seconds . "s ";
	if ($hours > 0) {
		$timeString = $minutes . "m " . $timeString;
		$timeString = $hours . "h " . $timeString;
	}
	elsif ($minutes > 0) {$timeString = $minutes . "m " . $timeString;}

	return $timeString;
}

########################## End of subroutines #####################################


if ($#ARGV < 0) {
	die ("Usage: perl rpm.pl <command>") unless ($#ARGV >= 0);
}
elsif ($ARGV[0] eq "update") {
	updateReports(\@systemsToMonitor);
}
elsif ($ARGV[0] eq "status") {
	sendReportStatusEmail("status");
}
elsif ($ARGV[0] eq "warning") {
	sendReportStatusEmail("warning");
}
else {
	die "Invalid command.  Valid commands are update, warning, and status\n";
}



