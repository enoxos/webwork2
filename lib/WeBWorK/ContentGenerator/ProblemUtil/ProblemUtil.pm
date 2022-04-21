################################################################################
# WeBWorK Online Homework Delivery System
# Copyright &copy; 2000-2021 The WeBWorK Project, https://github.com/openwebwork
#
# This program is free software; you can redistribute it and/or modify it under
# the terms of either: (a) the GNU General Public License as published by the
# Free Software Foundation; either version 2, or (at your option) any later
# version, or (b) the "Artistic License" which comes with this package.
#
# This program is distributed in the hope that it will be useful, but WITHOUT
# ANY WARRANTY; without even the implied warranty of MERCHANTABILITY or FITNESS
# FOR A PARTICULAR PURPOSE.  See either the GNU General Public License or the
# Artistic License for more details.
################################################################################

# Created to house most output subroutines for Problem.pm to make that module more lightweight
# Now mostly defunct due to having moved most of the output declarations to the template
# -ghe3

package WeBWorK::ContentGenerator::ProblemUtil::ProblemUtil;
use base qw(WeBWorK);
use base qw(WeBWorK::ContentGenerator);

=head1 NAME

WeBWorK::ContentGenerator::ProblemUtil::ProblemUtil - contains a bunch of subroutines for generating output for the problem pages, especially those generated by Problem.pm

=cut

use strict;
use warnings;
#use CGI qw(-nosticky );
use WeBWorK::CGI;
use File::Path qw(rmtree);
use WeBWorK::Debug;
use WeBWorK::Form;
use WeBWorK::PG;
use WeBWorK::PG::ImageGenerator;
use WeBWorK::PG::IO;
use WeBWorK::Utils qw(readFile writeLog writeCourseLog encodeAnswers decodeAnswers
	ref2string makeTempDirectory path_is_subdir sortByName before after between jitar_problem_adjusted_status jitar_id_to_seq);
use WeBWorK::DB::Utils qw(global2user user2global);
use URI::Escape;
use WeBWorK::Authen::LTIAdvanced::SubmitGrade;
use WeBWorK::Utils::Tasks qw(fake_set fake_problem);

use Email::Stuffer;
use Try::Tiny;

use Caliper::Sensor;
use Caliper::Entity;


# process_and_log_answer subroutine.

# performs functions of processing and recording the answer given in the page.
# Also returns the appropriate scoreRecordedMessage.

sub process_and_log_answer{

	my $self = shift;  #type is ref($self) eq 'WeBWorK::ContentGenerator::Problem'
	my $r = $self->r;
	my $db = $r->db;
	my $effectiveUser = $r->param('effectiveUser');
	my $authz = $r->authz;


	my %will = %{ $self->{will} };
	my $submitAnswers = $self->{submitAnswers};
	my $problem = $self->{problem};
	my $pg = $self->{pg};
	my $set = $self->{set};
	my $urlpath = $r->urlpath;
	my $courseID = $urlpath->arg("courseID");

	# logging student answers
	my $pureProblem = $db->getUserProblem($problem->user_id, $problem->set_id, $problem->problem_id); # checked
	my $answer_log    = $self->{ce}->{courseFiles}->{logs}->{'answer_log'};

    my ($encoded_last_answer_string, $scores2, $isEssay2);
	my $scoreRecordedMessage = "";

	if (defined($answer_log) && defined($pureProblem) && $submitAnswers) {
		my $past_answers_string;
		($past_answers_string, $encoded_last_answer_string, $scores2, $isEssay2) =
			WeBWorK::ContentGenerator::ProblemUtil::ProblemUtil::create_ans_str_from_responses($self, $pg);

		if (!$authz->hasPermissions($effectiveUser, "dont_log_past_answers")) {
			# store in answer_log
			my $timestamp = time();
			writeCourseLog($self->{ce}, "answer_log",
				join("",
					'|', $problem->user_id,
					'|', $problem->set_id,
					'|', $problem->problem_id,
					'|', $scores2, "\t",
					$timestamp,"\t",
					$past_answers_string,
				),
			);

			# add to PastAnswer db
			my $pastAnswer = $db->newPastAnswer();
			$pastAnswer->course_id($courseID);
			$pastAnswer->user_id($problem->user_id);
			$pastAnswer->set_id($problem->set_id);
			$pastAnswer->problem_id($problem->problem_id);
			$pastAnswer->timestamp($timestamp);
			$pastAnswer->scores($scores2);
			$pastAnswer->answer_string($past_answers_string);
			$pastAnswer->source_file($problem->source_file);
			$db->addPastAnswer($pastAnswer);
		}
	}

######################################################################
# this stores previous answers to the problem to
# provide "sticky answers"

	if ($submitAnswers) {
		# get a "pure" (unmerged) UserProblem to modify
		# this will be undefined if the problem has not been assigned to this user

		if (defined $pureProblem) {
			# store answers in DB for sticky answers
			my %answersToStore;

			# store last answer to database for use in "sticky" answers
			$problem->last_answer($encoded_last_answer_string);
			$pureProblem->last_answer($encoded_last_answer_string);
			$db->putUserProblem($pureProblem);

			# store state in DB if it makes sense
			if ($will{recordAnswers}) {
				$problem->status($pg->{state}->{recorded_score});
				$problem->sub_status($pg->{state}->{sub_recorded_score});
				$problem->attempted(1);
				$problem->num_correct($pg->{state}->{num_of_correct_ans});
				$problem->num_incorrect($pg->{state}->{num_of_incorrect_ans});
				$pureProblem->status($pg->{state}->{recorded_score});
				$pureProblem->sub_status($pg->{state}->{sub_recorded_score});
				$pureProblem->attempted(1);
				$pureProblem->num_correct($pg->{state}->{num_of_correct_ans});
				$pureProblem->num_incorrect($pg->{state}->{num_of_incorrect_ans});

				#add flags for an essay question.  If its an essay question and
				# we are submitting then there could be potential changes, and it should
				# be flaged as needing grading
				# we shoudl also check for the appropriate flag in the global problem and set it

				if ($isEssay2 && $pureProblem->{flags} !~ /needs_grading/) {
				    $pureProblem->{flags} =~ s/graded,//;
				    $pureProblem->{flags} .= "needs_grading,";
				}

				my $globalProblem = $db->getGlobalProblem($problem->set_id, $problem->problem_id);
				if ($isEssay2 && $globalProblem->{flags} !~ /essay/) {
				    $globalProblem->{flags} .= "essay,";
				    $db->putGlobalProblem($globalProblem);
				} elsif (!$isEssay2 && $globalProblem->{flags} =~ /essay/) {
				    $globalProblem->{flags} =~ s/essay,//;
				    $db->putGlobalProblem($globalProblem);
				}

				if ($db->putUserProblem($pureProblem)) {
					$scoreRecordedMessage = $r->maketext("Your score was recorded.");
				} else {
					$scoreRecordedMessage = $r->maketext("Your score was not recorded because there was a failure in storing the problem record to the database.");
				}
				# write to the transaction log, just to make sure
				writeLog($self->{ce}, "transaction",
					$problem->problem_id."\t".
					$problem->set_id."\t".
					$problem->user_id."\t".
					$problem->source_file."\t".
					$problem->value."\t".
					$problem->max_attempts."\t".
					$problem->problem_seed."\t".
					$pureProblem->status."\t".
					$pureProblem->attempted."\t".
					$pureProblem->last_answer."\t".
					$pureProblem->num_correct."\t".
					$pureProblem->num_incorrect
					);

				my $caliper_sensor = Caliper::Sensor->new($self->{ce});
				if ($caliper_sensor->caliperEnabled() && defined($answer_log) && !$authz->hasPermissions($effectiveUser, "dont_log_past_answers")) {
					my $startTime = $r->param('startTime');
					my $endTime = time();

					my $completed_question_event = {
						'type' => 'AssessmentItemEvent',
						'action' => 'Completed',
						'profile' => 'AssessmentProfile',
						'object' => Caliper::Entity::problem_user(
							$self->{ce},
							$db,
							$problem->set_id(),
							0, #version is 0 for non-gateway problems
							$problem->problem_id(),
							$problem->user_id(),
							$pg
						),
						'generated' => Caliper::Entity::answer(
							$self->{ce},
							$db,
							$problem->set_id(),
							0, #version is 0 for non-gateway problems
							$problem->problem_id(),
							$problem->user_id(),
							$pg,
							$startTime,
							$endTime
						),
					};
					my $submitted_set_event = {
						'type' => 'AssessmentEvent',
						'action' => 'Submitted',
						'profile' => 'AssessmentProfile',
						'object' => Caliper::Entity::problem_set(
							$self->{ce},
							$db,
							$problem->set_id()
						),
						'generated' => Caliper::Entity::problem_set_attempt(
							$self->{ce},
							$db,
							$problem->set_id(),
							0, #version is 0 for non-gateway problems
							$problem->user_id(),
							$startTime,
							$endTime
						),
					};
					my $tool_use_event = {
						'type' => 'ToolUseEvent',
						'action' => 'Used',
						'profile' => 'ToolUseProfile',
						'object' => Caliper::Entity::webwork_app(),
					};
					$caliper_sensor->sendEvents($r, [$completed_question_event, $submitted_set_event, $tool_use_event]);

					# reset start time
					$r->param('startTime', '');
				}

				#Try to update the student score on the LMS
				# if that option is enabled.
				my $LTIGradeMode = $self->{ce}{LTIGradeMode} // '';
				if ($LTIGradeMode && $self->{ce}{LTIGradeOnSubmit}) {
					my $grader = WeBWorK::Authen::LTIAdvanced::SubmitGrade->new($r);
					if ($LTIGradeMode eq 'course') {
						if ($grader->submit_course_grade($problem->user_id)) {
							$scoreRecordedMessage .=
								CGI::br() . $r->maketext('Your score was successfully sent to the LMS.');
						} else {
							$scoreRecordedMessage .=
								CGI::br() . $r->maketext('Your score was not successfully sent to the LMS.');
						}
					} elsif ($LTIGradeMode eq 'homework') {
						if ($grader->submit_set_grade($problem->user_id, $problem->set_id)) {
							$scoreRecordedMessage .=
								CGI::br() . $r->maketext('Your score was successfully sent to the LMS.');
						} else {
							$scoreRecordedMessage .=
								CGI::br() . $r->maketext('Your score was not successfully sent to the LMS.');
						}
					}
				}
			} else {
				if (before($set->open_date) or after($set->due_date)) {
					$scoreRecordedMessage = $r->maketext("Your score was not recorded because this homework set is closed.");
				} else {
					$scoreRecordedMessage = $r->maketext("Your score was not recorded.");
				}
			}
		} else {
			$scoreRecordedMessage = $r->maketext("Your score was not recorded because this problem has not been assigned to you.");
		}
	}


	$self->{scoreRecordedMessage} = $scoreRecordedMessage;
	return $scoreRecordedMessage;
}

# create answer string from responses hash
# ($past_answers_string, $encoded_last_answer_string, $scores, $isEssay) = create_ans_str_from_responses($problem, $pg)
#
# input: ref($pg)eq 'WeBWorK::PG::Local'
#        ref($problem)eq 'WeBWorK::ContentGenerator::Problem
# output:  (str, str, str)


# 2020_05 MEG  -- previous version seems to have omitted saving $pg->{flags}->{KEPT_EXTRA_ANSWERS} which also
# labels stored in $PG->{PERSISTANCE_HASH}
# 2020_05a MEG -- past_answers_string is being created for use in the past_answer table
# and other persistant objects need not be included.
# The extra persistence objects do need to be included in problem->last_answer
# in order to keep those objects persistant -- as long as RECORD_FORM_ANSWER
# is used to preserve objects by piggy backing on the persistence mechanism for answers.

sub create_ans_str_from_responses {
	my $problem = shift;  #  ref($problem) eq 'WeBWorK::ContentGenerator::Problem'
	                   	  #  must contain $self->{formFields}->{$response_id}
	my $pg = shift;       # ref($pg) eq 'WeBWorK::PG::Local'
	#warn "create_ans_str_from_responses pg has type ", ref($pg);
	my $scores2='';
	my $isEssay2=0;
	my %answers_to_store;
	my @past_answers_order;
	my @last_answer_order;

	my %pg_answers_hash = %{ $pg->{pgcore}->{PG_ANSWERS_HASH}};
	foreach my $ans_id (@{$pg->{flags}->{ANSWER_ENTRY_ORDER}//[]} ) {
		$scores2.= ($pg_answers_hash{$ans_id}->{ans_eval}{rh_ans}{score}//0) >= 1 ? "1" : "0";
		$isEssay2 = 1 if ($pg_answers_hash{$ans_id}->{ans_eval}{rh_ans}{type}//'') eq 'essay';
		foreach my $response_id ($pg_answers_hash{$ans_id}->response_obj->response_labels) {
			$answers_to_store{$response_id} = $problem->{formFields}->{$response_id};
			push @past_answers_order, $response_id;
			push @last_answer_order, $response_id;
		 }
	}
	# KEPT_EXTRA_ANSWERS need to be stored in last_answer in order to preserve persistence items
	# the persistence items do not need to be stored in past_answers_string
	foreach my $entry_id (@{ $pg->{flags}->{KEPT_EXTRA_ANSWERS} }) {
		next if exists( $answers_to_store{$entry_id}  );
		$answers_to_store{$entry_id}= $problem->{formFields}->{$entry_id};
		push @last_answer_order, $entry_id;
	}

	my $past_answers_string = '';
	foreach my $response_id (@past_answers_order) {
		$past_answers_string.=($answers_to_store{$response_id}//'')."\t";
	}
	$past_answers_string=~s/\t$//; # remove last tab

	my $encoded_last_answer_string = encodeAnswers(%answers_to_store,
							 @last_answer_order);
	# warn "$encoded_last_answer_string", $encoded_last_answer_string;
    # past_answers_string is stored in past_answer table
    # encoded_last_answer_string is used in `last_answer` entry of the problem_user table
	return ($past_answers_string,$encoded_last_answer_string, $scores2,$isEssay2);
}

# process_editorLink subroutine

# Creates and returns the proper editor link for the current website.  Also checks for translation errors and prints an error message and returning a false value if one is detected.

sub process_editorLink{

	my $self = shift;

	my $set = $self->{set};
	my $problem = $self->{problem};
	my $pg = $self->{pg};

	my $r = $self->r;

	my $authz = $r->authz;
	my $urlpath = $r->urlpath;
	my $user = $r->param('user');

	my $courseName = $urlpath->arg("courseID");

	# FIXME: move editor link to top, next to problem number.
	# format as "[edit]" like we're doing with course info file, etc.
	# add edit link for set as well.
	my $editorLink = "";
	# if we are here without a real homework set, carry that through
	my $forced_field = [];
	$forced_field = ['sourceFilePath' =>  $r->param("sourceFilePath")] if
		($set->set_id eq 'Undefined_Set');
	if ($authz->hasPermissions($user, "modify_problem_sets")) {
		my $editorPage = $urlpath->newFromModule("WeBWorK::ContentGenerator::Instructor::PGProblemEditor",
			courseID => $courseName, setID => $set->set_id, problemID => $problem->problem_id);
		my $editorURL = $self->systemLink($editorPage, params=>$forced_field);
		$editorLink = CGI::p(CGI::a({href=>$editorURL,target =>'WW_Editor'}, "Edit this problem"));
	}

	##### translation errors? #####

	if ($pg->{flags}->{error_flag}) {
		if ($authz->hasPermissions($user, "view_problem_debugging_info")) {
			print $self->errorOutput($pg->{errors}, $pg->{body_text});
		} else {
			print $self->errorOutput($pg->{errors}, "You do not have permission to view the details of this error.");
		}
		print $editorLink;
		return "permission_error";
	}
	else{
		return $editorLink;
	}
}

# output_main_form subroutine.

# prints out the main form for the page.  This particular subroutine also takes in $editorLink and $scoreRecordedMessage
# as required parameters.  Also prints out the score summary where applicable.

sub output_main_form{

	my $self = shift;
	my $editorLink = shift;

	my $r = $self->r;
	my $pg = $self->{pg};
	my $problem = $self->{problem};
	my $set = $self->{set};
	my $submitAnswers = $self->{submitAnswers};
	my $startTime = $r->param('startTime') || time();

	my $db = $r->db;
	my $ce = $r->ce;
	my $user = $r->param('user');
	my $effectiveUser = $r->{'effectiveUser'};

	my %can = %{ $self->{can} };
	my %will = %{ $self->{will} };

	print "\n";
	print CGI::start_form({
		method  => "POST",
		action  => $r->uri,
		name    => "problemMainForm",
		class   => 'problem-main-form'
	});
	print $self->hidden_authen_fields;
	print CGI::hidden({-name=>'startTime', -value=>$startTime});
	print CGI::end_form();
}

# output_footer subroutine

# prints out the footer elements to the page.

sub output_footer{

	my $self = shift;
	my $r = $self->r;
	my $problem = $self->{problem};
	my $pg = $self->{pg};
	my %will = %{ $self->{will} };

	my $authz = $r->authz;
	my $urlpath = $r->urlpath;
	my $user = $r->param('user');

	my $courseName = $urlpath->arg("courseID");

	print CGI::start_div({class=>"problemFooter"});


	my $pastAnswersPage = $urlpath->newFromModule("WeBWorK::ContentGenerator::Instructor::ShowAnswers",
		courseID => $courseName);
	my $showPastAnswersURL = $self->systemLink($pastAnswersPage, authen => 0); # no authen info for form action

	# print answer inspection button
	if ($authz->hasPermissions($user, "view_answers")) {
		print "\n",
			CGI::start_form(-method=>"POST",-action=>$showPastAnswersURL,-target=>"WW_Info"),"\n",
			$self->hidden_authen_fields,"\n",
			CGI::hidden(-name => 'courseID',  -value=>$courseName), "\n",
			CGI::hidden(-name => 'problemID', -value=>$problem->problem_id), "\n",
			CGI::hidden(-name => 'setID',  -value=>$problem->set_id), "\n",
			CGI::hidden(-name => 'studentUser',    -value=>$problem->user_id), "\n",
			CGI::p({ -align=>"left" },
				CGI::submit({ name => 'action',  value => 'Show Past Answers', class => 'btn btn-primary' })
			), "\n",
			CGI::end_form();
	}


	print $self->feedbackMacro(
		module             => __PACKAGE__,
		courseId           => $courseName,
		set                => $self->{set}->set_id,
		problem            => $problem->problem_id,
		problemPath        => $problem->source_file,
		randomSeed         => $problem->problem_seed,
		emailAddress       => join(";",$self->fetchEmailRecipients('receive_feedback',$user)),
		emailableURL       => $self->generateURLs(url_type => 'absolute',
		                                          set_id => $self->{set}->set_id,
		                                          problem_id => $problem->problem_id),
		studentName        => $user->full_name,
		displayMode        => $self->{displayMode},
		showOldAnswers     => $will{showOldAnswers},
		showCorrectAnswers => $will{showCorrectAnswers},
		showHints          => $will{showHints},
		showSolutions      => $will{showSolutions},
		pg_object          => $pg,
	);

	print CGI::end_div();
}

# check_invalid subroutine

# checks to see if the current problem set is valid for the current user, returns "valid" if it is and an error message if it's not.

sub check_invalid{

	my $self = shift;
	my $r = $self->r;
	my $urlpath = $r->urlpath;
	my $effectiveUser = $r->param('effectiveUser');

	if ($self->{invalidSet}) {
		return CGI::div(
			{ class => 'alert alert-danger' },
			CGI::p(
				"The selected problem set (" . $urlpath->arg("setID") . ") is not " . "a valid set for $effectiveUser:"
			),
			CGI::p($self->{invalidSet})
		);
	} elsif ($self->{invalidProblem}) {
		return CGI::div(
			{ class => 'alert alert-danger' },
			CGI::p(
				"The selected problem ("
					. $urlpath->arg("problemID")
					. ") is not a valid problem for set "
					. $self->{set}->set_id . "."
			)
		);
	} else {
		return "valid";
	}

}

sub test{
	print "test";
}

# if you provide this subroutine with a userProblem it will notify the
# instructors of the course that the student has finished the problem,
# and its children, and did not get 100%
sub jitar_send_warning_email {
    my $self = shift;
    my $userProblem = shift;

    my $r= $self->r;
    my $ce = $r->ce;
    my $db = $r->db;
    my $authz = $r->authz;
    my $urlpath    = $r->urlpath;
    my $courseID = $urlpath->arg("courseID");
    my $userID = $userProblem->user_id;
    my $setID = $userProblem->set_id;
    my $problemID = $userProblem->problem_id;

    my $status = jitar_problem_adjusted_status($userProblem,$r->db);
    $status = eval{ sprintf("%.0f%%", $status * 100)}; # round to whole number

    my $user = $db->getUser($userID);

    debug("Couldn't get user $userID from database") unless $user;

    my $emailableURL = $self->systemLink(
	$urlpath->newFromModule("WeBWorK::ContentGenerator::Problem", $r,
				courseID => $courseID, setID => $setID, problemID => $problemID), params=>{effectiveUser=>$userID}, use_abs_url=>1);


	  my @recipients = $self->fetchEmailRecipients("score_sets", $user);
        # send to all users with permission to score_sets and an email address

    my $sender;
	if ($user->email_address) {
		$sender = $user->rfc822_mailbox;
	} elsif ($user->full_name) {
		$sender = $user->full_name;
	} else {
		$sender = $userID;
	}

    $problemID = join('.',jitar_id_to_seq($problemID));

    my %subject_map = (
	'c' => $courseID,
	'u' => $userID,
	's' => $setID,
	'p' => $problemID,
	'x' => $user->section,
	'r' => $user->recitation,
	'%' => '%',
	);
    my $chars = join("", keys %subject_map);
    my $subject = $ce->{mail}{feedbackSubjectFormat}
    || "WeBWorK question from %c: %u set %s/prob %p"; # default if not entered
    $subject =~ s/%([$chars])/defined $subject_map{$1} ? $subject_map{$1} : ""/eg;

    my $full_name = $user->full_name;
    my $email_address = $user->email_address;
    my $student_id = $user->student_id;
    my $section = $user->section;
    my $recitation = $user->recitation;
    my $comment = $user->comment;

    # print message
my $msg = qq/
This  message was automatically generated by WeBWorK.

User $full_name ($userID) has not sucessfully completed the review for problem $problemID in set $setID.  Their final adjusted score on the problem is $status.

Click this link to visit the problem: $emailableURL

User ID:    $userID
Name:       $full_name
Email:      $email_address
Student ID: $student_id
Section:    $section
Recitation: $recitation
Comment:    $comment
/;

	my $email = Email::Stuffer->to(join(",", @recipients))->from($sender)->subject($subject)
		->text_body(Encode::encode('UTF-8', $msg));

	# Extra headers
	$email->header('X-WeBWorK-Course: ', $courseID) if defined $courseID;
	if ($user) {
		$email->header('X-WeBWorK-User: ',       $user->user_id);
		$email->header('X-WeBWorK-Section: ',    $user->section);
		$email->header('X-WeBWorK-Recitation: ', $user->recitation);
	}
	$email->header('X-WeBWorK-Set: ',     $setID)     if defined $setID;
	$email->header('X-WeBWorK-Problem: ', $problemID) if defined $problemID;

	# $ce->{mail}{set_return_path} is the address used to report returned email if defined and non empty.
	# It is an argument used in sendmail() (aka Email::Stuffer::send_or_die).
	# For arcane historical reasons sendmail actually sets the field "MAIL FROM" and the smtp server then
	# uses that to set "Return-Path".
	# references:
	#  https://stackoverflow.com/questions/1235534/what-is-the-behavior-difference-between-return-path-reply-to-and-from
	#  https://metacpan.org/pod/Email::Sender::Manual::QuickStart#envelope-information
	try {
		$email->send_or_die({
				# createEmailSenderTransportSMTP is defined in ContentGenerator
				transport => $self->createEmailSenderTransportSMTP(),
				$ce->{mail}{set_return_path} ? (from => $ce->{mail}{set_return_path}) : ()
			});
		debug('Successfully sent JITAR alert message');
	} catch {
		$r->log_error("Failed to send JITAR alert message: $_");
	};

    return '';
}

1;
