###############################################################################
# WeBWorK Online Homework Delivery System
# Copyright &copy; 2000-2022 The WeBWorK Project, https://github.com/openwebwork
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

package WeBWorK::Authen::LTIAdvanced;
use base qw/WeBWorK::Authen/;

=head1 NAME

WeBWorK::Authen::LTIAdvanced - Authenticate from a Learning Management System
via the IMS LTI Basic/OAuth protocol.

=cut

use strict;
use warnings;
use Carp;
use WeBWorK::Debug;
use DBI;
use WeBWorK::CGI;
use WeBWorK::Utils qw(formatDateTime);
use WeBWorK::Localize;
use WeBWorK::ContentGenerator::Instructor;
use URI::Escape;
use Net::OAuth;

$Net::OAuth::PROTOCOL_VERSION = Net::OAuth::PROTOCOL_VERSION_1_0A;

use APR::SockAddr;
use Apache2::Connection;
use APR::Request::Error;

=head1 CONSTRUCTOR

=over

=item new($r)

Instantiates a new WeBWorK::Authen object for the given WeBWorK::Requst ($r).

=cut

sub new {
  my ($invocant, $r) = @_;
  my $class = ref($invocant) || $invocant;
  my $self = {
	      r => $r,
	     };
  #initialize
  bless $self, $class;
  return $self;
}

=back

=cut

## this is only overridden for debug logging
#sub verify {
#	debug("BEGIN LTIAdvanced VERIFY");
#	my $result = $_[0]->SUPER::verify(@_[1..$#_]);
#	debug("END LTIAdvanced VERIFY");
#	return $result;
#}

# This module is similar to the base class, with these differences:
#  1. no WeBWorK guest/practice logins
#  2. uses the Key database to store nonces, where
#     the $Key->username = the nonce
#	  $Key->key = "nonce"
#	  $Key->timestamp = the nonce's timestamp

# Some LMS's misspell the lis_person_sourcedid parameter name
# so we use a list of variations when needed.
our @lis_person_sourcedid_options = (
	"lis_person_sourcedid", # from spec at https://www.imsglobal.org/specs/ltiv1p1/implementation-guide#toc-3
	"lis_person_sourced_id",
	"lis_person_source_id",
	"lis_person_sourceid"
);

sub  request_has_data_for_this_verification_module {
  debug("LTIAdvanced has been called for data verification");
  my $self = shift;
  my $r = $self->{r};

  # See comment in get_credentials()
  if ($r->{xmlrpc}) {
    debug("LTIAdvanced returning 1 because it is an xmlrpc call");
    return 1;
  }

  # We need at least these things to verify an oauth request
  if (!(defined $r->param("oauth_consumer_key"))
      || !(defined $r->param("oauth_signature"))
      || !(defined $r->param("oauth_nonce"))
      || !(defined $r->param("oauth_timestamp")) ) {
    debug("LTIAdvanced returning that it has insufficent data");
    return(0);
  } else {
    debug("LTIAdvanced returning that it has sufficient data");
    return(1);
  }
}

sub get_credentials {
  my $self = shift;
  my $r = $self->{r};
  my $ce = $r->{ce};

  debug("LTIAdvanced::get_credentials has been called\n");

  ## Printing parameters to main page can help people set things up
  ## so we dont use the debug channel here
  if ( $ce->{debug_lti_parameters} ) {
    my $rh_headers = $r->headers_in;  #request headers

    my @parameter_names = $r->param;       # form parameter names
    my $parameter_report = '';
    foreach my $key (@parameter_names) {
      $parameter_report .= "$key => ".$r->param($key). "\n";
    }
    warn ("===== parameters received =======\n", $parameter_report);
  }

  my $oauth_time = $r->param("oauth_timestamp");
  my $curr_time = time();
  my $delta_time = $curr_time - $oauth_time;
  my $delta_min = (0.0 + $delta_time) / (60.0);
  if ( $ce->{debug_lti_parameters} ) {
    warn join("\n",
	"============================",
	"===== timestamp info =======",
	"oauth_nonce        = $oauth_time",
	"WW_server_time     = $curr_time",
	"diff(server-oauth) = $delta_time seconds ($delta_min minutes)",
	"============================"
    );
  }

  #disable password login
  $self->{external_auth} = 1;

  # This next part is necessary because some parts of webwork (e.g.,
  # WebworkWebservice.pm) need to replace the get_credentials() routine,
  # but only replace the one in the parent class (out of caution,
  # presumably).	Therefore, we end up here even when authenticating
  # for WebworkWebservice.pm.  This would cause authentication failures
  # when authenticating javascript web service requests (e.g., the
  # Library Browser).
  # Similar changes are needed in check_user() and verify_normal_user().

  if ($r->{xmlrpc}) {
    debug("falling back to superclass get_credentials (xmlrpc call)");
    return $self->SUPER::get_credentials(@_);
  }

  # Determine the WW user_id to use, if possible

  if ( ! $ce->{preferred_source_of_username} ) {
    warn "LTI is not properly configured (no preferred_source_of_username). Please contact your instructor or system administrator.";
    $self->{error} = $r->maketext("There was an error during the login process.  Please speak to your instructor or system administrator.");
    debug("No preferred_source_of_username in " . $r->ce->{'courseName'} . " so LTIAdvanced::get_credentials is returning a 0\n");
    return 0;
  }

  my $user_id_source = "";
  my $type_of_source = "";

  $self->{email} = ""; # set an initial value to avoid warnings when not provided
  if ( defined( $r->param("lis_person_contact_email_primary") ) ) {
	$self->{email} = uri_unescape($r->param("lis_person_contact_email_primary")) // "";
  }

  if ( $ce->{preferred_source_of_username} eq "lis_person_sourcedid" ) {
	foreach my $key ( @lis_person_sourcedid_options ) {
		if ( $r->param($key) ) {
			$user_id_source = $key;
			$type_of_source = "preferred_source_of_username";
			$self->{user_id} = $r->param($key);
			last;
		}
	}
  } elsif ( $ce->{preferred_source_of_username} eq "lis_person_contact_email_primary"
	&& $self->{email} ne "" ) {
	$user_id_source = "lis_person_contact_email_primary";
	$type_of_source = "preferred_source_of_username";
	$self->{user_id} = $self->{email};

	# Strip off the part of the address after @ if requested to do so:
	$self->{user_id} =~ s/@.*$// if $ce->{strip_address_from_email};
  } elsif ( $r->param($ce->{preferred_source_of_username}) ) {
	$user_id_source = $ce->{preferred_source_of_username};
	$type_of_source = "preferred_source_of_username";
	$self->{user_id} = $r->param($ce->{preferred_source_of_username});
  }

  # Fallback if necessary
  if ( !defined( $self->{user_id} ) && $ce->{fallback_source_of_username} ) {
	if ( $ce->{fallback_source_of_username} eq "lis_person_sourcedid" ) {
		foreach my $key ( @lis_person_sourcedid_options ) {
			if ( $r->param($key) ) {
				$user_id_source = $key;
				$type_of_source = "fallback_source_of_username";
				$self->{user_id} = $r->param($key);
				last;
			}
		}
	} elsif ( $ce->{fallback_source_of_username} eq "lis_person_contact_email_primary"
		&& $self->{email} ne "" ) {
		$user_id_source = "lis_person_contact_email_primary";
		$type_of_source = "fallback_source_of_username";
		$self->{user_id} = $self->{email};

		# Strip off the part of the address after @ if requested to do so:
		$self->{user_id} =~ s/@.*$// if $ce->{strip_address_from_email};
	} elsif ( $r->param($ce->{fallback_source_of_username}) ) {
		$user_id_source = $ce->{fallback_source_of_username};
		$type_of_source = "fallback_source_of_username";
		$self->{user_id} = $r->param($ce->{fallback_source_of_username});
	}
  }

  # if we were able to set a user_id
  if ( defined($self->{user_id}) && $self->{user_id} ne "" ) {
	# Make user_id lowercase for consistency in naming if configured.
	$self->{user_id} = lc($self->{user_id}) if ($ce->{lti_lowercase_username});

      map {$self->{$_->[0]} = $r->param($_->[1]);}
	(
	 ['role', 'roles'],
	 ['last_name' , 'lis_person_name_family'],
	 ['first_name', 'lis_person_name_given'],
	 ['context_id', 'context_id'],
	 ['oauth_consumer_key', 'oauth_consumer_key'],
	 ['oauth_signature', 'oauth_signature'],
	 ['oauth_nonce', 'oauth_nonce'],
	 ['oauth_timestamp', 'oauth_timestamp'],
	 ['section', 'custom_section'],
	 ['recitation', 'custom_recitation'],
	);

      if (defined($ce->{preferred_source_of_student_id})
	&& defined($r->param($ce->{preferred_source_of_student_id}))) {
	$self->{student_id} = $r->param($ce->{preferred_source_of_student_id});
      } else {
	$self->{student_id} = ""; # fall back to avoid a warning when debug_lti_parameters enabled
      }

      # For setting up its helpful to print out what the system think the
      # User id and address is at this point
      if ( $ce->{debug_lti_parameters} ) {
	warn "=========== summary ============";
	warn "User id is |$self->{user_id}| (obtained from $user_id_source which was $type_of_source)\n";
	warn "User mail address is |$self->{email}|\n";
	warn "strip_address_from_email is |", $ce->{strip_address_from_email}//0,"|\n";
	warn "Student id is |$self->{student_id}|\n";
	warn "preferred_source_of_username is |$ce->{preferred_source_of_username}|\n";
	warn "fallback_source_of_username is |", $ce->{fallback_source_of_username}//'undefined',"|\n";
	warn "preferred_source_of_student_id is |", $ce->{preferred_source_of_student_id}//'undefined',"|\n";
	warn "================================\n";
      }
      if (!defined($self->{user_id})) {
	croak "LTIAdvanced was unable to create a username from the data provided with the current settings. Set \$debug_lti_parameters=1 in authen_LTI.conf to debug";
      }

      $self->{login_type} = "normal";
      $self->{credential_source} = "LTIAdvanced";
      debug("LTIAdvanced::get_credentials is returning a 1\n");
      return 1;
    }
  warn "LTI is not properly configured (failed to set user_id from preferred_source_of_username or fallback_source_of_username). Please contact your instructor or system administrator.";
  $self->{error} = $r->maketext("There was an error during the login process.  Please speak to your instructor or system administrator.");
  debug("LTIAdvanced::get_credentials is returning a 0\n");
  return 0;
}

# minor modification of method in superclass
sub check_user {
  my $self = shift;
  my $r = $self->{r};
  my ($ce, $db, $authz) = map {$r->$_ ;} ('ce', 'db', 'authz');

  my $user_id = $self->{user_id};

  debug("LTIAdvanced::check_user has been called for user_id = |$user_id|");

  # See comment in get_credentials()
  if ($r->{xmlrpc}) {
    #debug("falling back to superclass check_user (xmlrpc call)");
    return $self->SUPER::check_user(@_);
  }

  if (!defined($user_id) || (defined $user_id && $user_id eq "")) {
    $self->{log_error} .= "no user id specified";
    $self->{error} = $r->maketext("There was an error during the login process.  Please speak to your instructor or system administrator.");
    return 0;
  }

  my $User = $db->getUser($user_id);

  if (!$User) {
    my %options;
    $options{$ce->{preferred_source_of_username}} = 1 if ($ce->{preferred_source_of_username});
    $options{$ce->{fallback_source_of_username}}  = 1 if ($ce->{fallback_source_of_username});

    # May need to add alternate "spellings" for lis_person_sourcedid
    my $use_lis_person_sourcedid_options = 0;
    if ( defined($ce->{preferred_source_of_username})
	&& $ce->{preferred_source_of_username} eq "lis_person_sourcedid" ) {
	$use_lis_person_sourcedid_options = 1;
    } elsif ( defined($ce->{fallback_source_of_username})
	&& $ce->{fallback_source_of_username} eq "lis_person_sourcedid" ) {
	$use_lis_person_sourcedid_options = 1;
    }

    foreach my $key ( keys( %options ), ( $use_lis_person_sourcedid_options ? @lis_person_sourcedid_options : () ) ) {
	if ( defined($r->param($key)) ) {
		debug("User |$user_id| is unknown but may be an new user from an LSM via LTI. Saw a value for $key About to return a 1");
		return 1;  #This may be a new user coming in from a LMS via LTI.
	}
    }

    $self->{log_error} .= " $user_id - user unknown";
    $self->{error} = $r->maketext("There was an error during the login process.  Please speak to your instructor or system administrator.");
    return 0;
  }

  unless ($ce->status_abbrev_has_behavior($User->status, "allow_course_access")) {
    $self->{log_error} .= "LOGIN FAILED $user_id - course access denied";
    $self->{error} = $r->maketext("Authentication failed.  Please speak to your instructor.");
    return 0;
  }

  unless ($authz->hasPermissions($user_id, "login")) {
    $self->{log_error} .= "LOGIN FAILED $user_id - no permission to login";
    $self->{error} = $r->maketext("Authentication failed.  Please speak to your instructor.");
    return 0;
  }

  debug("LTIAdvanced::check_user is about to return a 1.");
  return 1;
}

# disable practice users
sub verify_practice_user { return(0) ;}

sub verify_normal_user {
  my $self = shift;
  my ($r, $user_id, $session_key)
    = map {$self->{$_};} ('r', 'user_id', 'session_key');

  debug("LTIAdvanced::verify_normal_user called for user |$user_id|");

  # See comment in get_credentials()
  if ($r->{xmlrpc}) {
    #debug("falling back to superclass verify_normal_user (xmlrpc call)");
    return $self->SUPER::verify_normal_user(@_);
  }

  # Call check_session in order to destroy any existing session cookies and Key table sessions
  my ($sessionExists, $keyMatches, $timestampValid) = $self->check_session($user_id, $session_key, 0);

  debug("sessionExists='", $sessionExists, "' keyMatches='", $keyMatches, "' timestampValid='", $timestampValid, "'");

  my $auth_result = $self->authenticate;

  debug("auth_result=|${auth_result}|");

  # Parameters CANNOT be modified until after LTIAdvanced authentication
  # has been done, because the parameters passed with the request
  # are used in computing the OAuth_signature.  If there
  # are any changes in $r->{paramcache} (see Request.pm)
  # before authentication occurs, then authentication will FAIL
  # even if the consumer_secret is correct.

  $r->param("user" => $user_id);

  if ($auth_result eq "1") {
      $self->{session_key} = $self->create_session($user_id);
      debug("session_key=|" . $self->{session_key} . "|.");
      return 1;
    } else {
      $self->{error} = $auth_result;
      $self-> {log_error} .= "$user_id - authentication failed: ". $self->{error};
      return 0;
    }
}

sub authenticate {
  my $self = shift;
  my ($r, $user ) = map {$self->{$_};} ('r', 'user_id');

  # See comment in get_credentials()
  if ($r->{xmlrpc}) {
    #debug("falling back to superclass authenticate (xmlrpc call)");
    return $self->SUPER::authenticate(@_);
  }

  debug("LTIAdvanced::authenticate called for user |$user|");
  debug "ref(r) = |". ref($r) . "|";
  debug "ref of r->{paramcache} = |" . ref($r->{paramcache}) . "|";

  my $ce = $r->ce;
  my $db = $r->db;
  my $courseName = $r->ce->{'courseName'};

  # Check nonce to see whether request is legitimate
  debug("Nonce = |" . $self-> {oauth_nonce} . "|");
  my $nonce = WeBWorK::Authen::LTIAdvanced::Nonce->new($r, $self->{oauth_nonce}, $self->{oauth_timestamp});
  if (!($nonce->ok ) ) {
    $self->{error} .=  $r->maketext("There was an error during the login process.  Please speak to your instructor or system administrator if this recurs.");
    debug("Failed to verify nonce");
    return 0;
  }

  debug( "r->param(oauth_signature) = |" . $r->param("oauth_signature") . "|");
  my %request_hash;
  my @keys = keys %{$r-> {paramcache}};
  foreach my $key (@keys) {
    $request_hash{$key} =  $r->param($key);
    debug("$key->|" . $request_hash{$key} . "|");
  }
  my $requestHash = \%request_hash;

  # We need to provide the request URL when verifying the OAuth request.
  # We use the url request by default, but also allow it to be overriden
  my $path = $ce->{server_root_url}.$ce->{webwork_url};
  $path = $ce->{LTIBasicToThisSiteURL} ?
    $ce->{LTIBasicToThisSiteURL} : $path;

  # append the path the the server url
  $path = $path.$r->urlpath()->path;

  if ( $ce->{debug_lti_parameters} ) {
      warn("The following path was reconstructed by WeBWorK.  It should match the path in the LMS:");
      warn($path);
  }

  # We also try a version without the trailing / in case that was not
  # included when the LMS user created the LMS link
  my $altpath = $path;
  $altpath =~ s/\/$//;

  my ($request, $altrequest);
  eval {
    $request = Net::OAuth->request("request token")->from_hash($requestHash,
	       request_url => $path,
	       request_method => "POST",
	       consumer_secret => $ce->{LTIBasicConsumerSecret},
							      );

    $altrequest = Net::OAuth->request("request token")->from_hash($requestHash,
		  request_url => $altpath,
		  request_method => "POST",
		  consumer_secret => $ce->{LTIBasicConsumerSecret},
								 );
  };

  if ($@) {
      debug("construction of Net::OAuth object failed: $@");
      debug( "eval failed: ", $@, "<br /><br />");

      $self->{error} .= $r->maketext("There was an error during the login process.  Please speak to your instructor or system administrator.");
      $self->{log_error} .= "Construction of OAuth request record failed";
      return 0;
  }

  if (! $request->verify && ! $altrequest->verify) {
      debug("LTIAdvanced::authenticate request-> verify failed");
      debug("OAuth verification Failed ");

      $self->{error} .= $r->maketext("There was an error during the login process.  Please speak to your instructor or system administrator.");
      $self->{log_error} .= "OAuth verification failed.  Check the Consumer Secret and that the URL in the LMS exactly matches the WeBWorK URL.";
      if ( $ce->{debug_lti_parameters} ) {
	warn("OAuth verification failed.  Check the Consumer Secret and that the URL in the LMS exactly matches the WeBWorK URL as defined in site.conf. E.G. Check that if you have https in the LMS url then you have https in \$server_root_url in site.conf");
      }
      return 0;
  } else {
      debug("OAuth verification SUCCEEDED !!");

      my $userID = $self->{user_id};

	# Indentation of the internal blocks below was modified to follow
	# the WW coding standard; however, the leading indentation of the
	# if/elsif/closing '}' was kept as in the original code for now.
	# Thus the apparenly overlarge indentation below.
      if (! $db->existsUser($userID) ) { # New User. Create User record
		if ( $ce->{block_lti_create_user} ) {
			# We don't yet have the next string in the PO/POT files - so the next line is disabled.
			# $r->maketext("Account creation is currently disabled in this course.  Please speak to your instructor or system administrator.");
			$self->{log_error} .= "Account creation blocked by block_lti_create_user setting. Did not create user $userID.";
			if ( $ce->{debug_lti_parameters} ) {
				warn("Account creation is currently disabled in this course.  Please speak to your instructor or system administrator.");
			}
			return 0;
		} else {
			# Attempt to create the user, and warn if that fails.
			unless ($self->create_user()) {
				$r->maketext("There was an error during the login process.  Please speak to your instructor or system administrator.");
				$self->{log_error} .= "Failed to create user $userID.";
				if ( $ce->{debug_lti_parameters} ) {
					warn("Failed to create user $userID.");
				}
			}
		}
      }  elsif ($ce->{LMSManageUserData}) {
		$self->{initial_login} = 1; # Set here so login gets logged, even for accounts which maybe_update_user() would not modify or when it fails to update
		# Existing user. Possibly modify demographic information and permission level.
		unless ( $self->maybe_update_user() ) {
			# Do not fail the login if data update failed
			# FIXME - In the future we would like the message below (and other warn messages in this file) to be sent via maketext.
			warn("The system failed to update some of your account information. Please speak to your instructor or system administrator.");
		}
      } else {
	$self->{initial_login} = 1; # Set here so login gets logged when $ce->{LMSManageUserData} is false
      }

      # If we are using grade passback then make sure the data
      # we need to submit the grade is kept up to date.
      my $LTIGradeMode = $ce->{LTIGradeMode} // '';
      if ($LTIGradeMode eq 'course' ||
	  $LTIGradeMode eq 'homework') {
	my $submitGrade = WeBWorK::Authen::LTIAdvanced::SubmitGrade->new($r);
	$submitGrade->update_sourcedid($userID);
      }

      return 1;
  }

  debug("LTIAdvanced is returning a failed authentication");
  $self->{error} = $r->maketext("There was an error during the login process.  Please speak to your instructor or system administrator.");
  return(0);
}

# create a new user trying to log in
sub create_user {
  my $self = shift;
  my $r = $self->{r};
  my $userID = $self->{user_id};
  my $ce = $r->ce;
  my $db = $r->db;
  my $courseName = $r->ce->{'courseName'};

  ############################################################
  # Determine the roles defined for this user by the LTI request
  # and assign a permission level on that basis.
  ############################################################
  my $LTIrolesString = $r->param("roles");
  my @LTIroles = split /,/, $LTIrolesString;

  #remove the urn string if its present
  s/^urn:lti:.*:ims\/lis\/// for @LTIroles;

  if ( $ce->{debug_lti_parameters} ) {
    warn "The adjusted LTI roles defined for this user are: \n--",
      join("\n--", @LTIroles), "\n",
      "Any initial ^urn:lti:.*:ims/lis/ segments have been stripped off.\n",
      "The user will be assigned the highest role defined for them\n",
      "========================\n"
    }

  my $nr = scalar(@LTIroles);
  if (! defined($ce->{userRoles}->{$ce->{LMSrolesToWeBWorKroles}->{$LTIroles[0]}})) {
    croak("Cannot find a WeBWorK role that corresponds to the LMS role of "
	  . $LTIroles[0] .".");
  }

  my $LTI_webwork_permissionLevel
    = $ce->{userRoles}->{$ce->{LMSrolesToWeBWorKroles}->{$LTIroles[0]}};
  if ($nr > 1) {
    for (my $j =1; $j < $nr; $j++) {
      my $wwRole = $ce->{LMSrolesToWeBWorKroles}->{$LTIroles[$j]};
      next unless defined $wwRole;
      if ($LTI_webwork_permissionLevel < $ce->{userRoles}->{$wwRole}) {
	$LTI_webwork_permissionLevel = $ce->{userRoles}->{$wwRole};
      }
    }
  }

  ####### End defining roles and $LTI_webwork_permissionLevel#######


  warn "New user: $userID -- requested permission level is $LTI_webwork_permissionLevel." if ( $ce->{debug_lti_parameters} );

  # We dont create users with too high of a permission level
  # for security reasons.
  if ($LTI_webwork_permissionLevel > $ce->{userRoles}->{$ce->{LTIAccountCreationCutoff}}) {
    $self->{log_error}.= "userID: $userID -- Unknown instructor attempting to log in via LTI.  Instructor accounts must be created manually";
    croak $r->maketext("The instructor account with user id [_1] does not exist.  Please create the account manually via WeBWorK.",$userID);
    return 0;
  }

  my $newUser = $db->newUser();
  $newUser->user_id($userID);
  $self->{last_name} =~ s/\+/ /g;
  $newUser->last_name($self->{last_name});
  $self->{first_name} =~ s/\+/ /g;
  $newUser->first_name($self->{first_name});
  $newUser->email_address($self->{email});
  $newUser->status("C");
  $newUser-> section($self->{section} // "");
  $newUser->recitation($self->{recitation} // "");
  $newUser->comment(formatDateTime(time, "local"));
  $newUser->student_id($self->{student_id} // "");

  # Allow sites to customize the user
  if (defined($ce->{LTI_modify_user})) {
    $ce->{LTI_modify_user}($self,$newUser);
  }

  $db->addUser($newUser);
  $self->write_log_entry("New user $userID added via LTIAdvanced login");

  # Assign permssion level
  my $newPermissionLevel = $db->newPermissionLevel();
  $newPermissionLevel->user_id($userID);
  $newPermissionLevel->permission($LTI_webwork_permissionLevel);
  $db->addPermissionLevel($newPermissionLevel);
  $r->authz->{PermissionLevel} = $newPermissionLevel;  #cache the Permission Level Record.


  # Assign existing sets
  my $instructorTools = WeBWorK::ContentGenerator::Instructor->new($r);
  my @setsToAssign = ();

  my @globalSetIDs = $db->listGlobalSets;
  my @GlobalSets = $db->getGlobalSets(@globalSetIDs);
  foreach my $globalSet (@GlobalSets) {
    # assign all visible or "published" sets
    if ($globalSet->visible) {
      push @setsToAssign, $globalSet;
      $instructorTools->assignSetToUser($userID,$globalSet);
    }
  }
  $self->{numberOfSetsAssigned} = scalar @setsToAssign;

	# Assign all existing achievements
	my @achievementIDs = $db->listAchievements;
	foreach my $achievementID (@achievementIDs) {
		my $achievement = $db->getAchievement($achievementID);
		if ($achievement->enabled) {
			my $userAchievement = $db->newUserAchievement();
			$userAchievement->user_id($userID);
			$userAchievement->achievement_id($achievementID);
			$db->addUserAchievement($userAchievement);
		}
	}
	# Initialize global achievement data
	my $globalUserAchievement = $db->newGlobalUserAchievement();
	$globalUserAchievement->user_id($userID);
	$globalUserAchievement->achievement_points(0);
	$db->addGlobalUserAchievement($globalUserAchievement);

  # Give schools the chance to modify newly added sets
  if (defined($ce->{LTI_modify_user_set})) {
    foreach my $globalSet (@setsToAssign) {
      my $userSet = $db->getUserSet($userID,$globalSet->set_id);
      next unless $userSet;

      $ce->{LTI_modify_user_set}($self,$globalSet,$userSet);
      $db->putUserSet($userSet);
    }
  }

  $self->{initial_login} = 1;

  return 1;
}

# possibly update a user logging in
sub maybe_update_user {
  my $self = shift;
  my $r = $self->{r};
  my $userID = $self->{user_id};
  my $ce = $r->ce;
  my $db = $r->db;
  my $courseName = $r->ce->{'courseName'};

  my $user = $db->getUser($userID);
  my $permissionLevel = $db->getPermissionLevel($userID);
  # We don't alter records of users with too high a permission
  if (defined($permissionLevel->permission) &&
	$permissionLevel->permission > $ce->{userRoles}->{$ce->{LTIAccountCreationCutoff}}) {
    return 1; # Treat as OK as not allowed to modify
  } else {
    # Create a temp user and run it through the create process
    my $tempUser = $db->newUser();
    $tempUser->user_id($userID);
    my $last_name = $self->{last_name} // '';
    $last_name =~ s/\+/ /g;
    $tempUser->last_name($last_name);
    my $first_name = $self->{first_name} // '';
    $first_name =~ s/\+/ /g;
    $tempUser->first_name($first_name);
    $tempUser->email_address($self->{email});
    $tempUser->status("C");
    $tempUser->section($self->{section} // "");
    $tempUser->recitation($self->{recitation} // "");
    $tempUser->student_id($self->{student_id} // "");

    # Allow sites to customize the temp user
    if (defined($ce->{LTI_modify_user})) {
      $ce->{LTI_modify_user}($self,$tempUser);
    }

    my @elements = qw(last_name first_name
		      email_address status
		      section recitation student_id);

    my $change_made = 0;

    for my $element (@elements) {
      if ($user->$element ne $tempUser->$element) {
	$change_made = 1;
	warn "WeBWorK User has $element: ".$user->$element." but LMS user has $element ".$tempUser->$element."\n"
	  if ( $ce->{debug_lti_parameters} );
      }
    }

    if ($change_made) {
      $tempUser->comment(formatDateTime(time, "local"));
      eval { $db->putUser($tempUser) };
      if ($@) {
        $self->write_log_entry("Failed to update user $userID in LTIAdvanced login: $@");
        warn "Failed to update user $userID in LTIAdvanced login.\n"
	  if ( $ce->{debug_lti_parameters} );
        return 0;
      } else {
        $self->write_log_entry("Demographic data for user $userID modified via LTIAdvanced login");
        warn "Existing user: $userID updated.\n"
	  if ( $ce->{debug_lti_parameters} );
	return 1;
      }
    } else {
      return 1; # No changes needed
    }
  }
}

################################################################################
# NONCE SUB-PACKAGE
################################################################################

package WeBWorK::Authen::LTIAdvanced::Nonce;

# This controls how often the key database is scrubbed for old nonce's
use constant NONCE_PURGE_FREQUENCY => 7200; # 2 hours

# This controls how old a nonce is before it is purged
use constant NONCE_LIFETIME => 21600; # 6 hours

sub new {
  my ($invocant, $r, $nonce, $timestamp) = @_;
  my $class = ref($invocant) || $invocant;
  my $self = {
	      r => $r,
	      nonce => $nonce,
	      timestamp => $timestamp,
	     };
  bless $self, $class;
  return $self;
}

sub ok {
  my $self = shift;
  my $r = $self->{r};
  my $ce = $r->{ce};
  my $db = $self->{r}->{db};

  $self->maybe_purge_nonces();

  if ($self->{timestamp} < time() - $ce->{NonceLifeTime}) {
    if ( $ce->{debug_lti_parameters} ) {
      warn("Nonce Expired.  Your NonceLifeTime may be too short");
    }
    return 0;
  }

  my $Key = $db->getKey($self->{nonce});
  # If we *haven't* used this nonce before then we are OK.
  if (! defined($Key) ) {
    # nonce, timestamp are ok.	Add the nonce so its not used again
    $Key = $db->newKey(user_id=>$self->{nonce},
		       key=>"nonce",
		       timestamp=>$self->{"timestamp"},
		      );
    $db->addKey($Key);
    return 1;
  } else {
    # The nonce is in the database - so was used "recently" so should NOT be allowed
    if ( $Key->timestamp <  $self->{"timestamp"} ) {
      # Update timestamp - so deletion will be delayed from the most recent value
      # of oauth_timestamp sent by the LTI consumer and not from an earlier timestamp.
      $Key->timestamp($self->{"timestamp"});
      $db->putKey($Key);
    }
    return 0;
  }
}

sub maybe_purge_nonces {
  my $self = shift;
  my $r = $self->{r};
  my $ce = $r->{ce};
  my $db = $self->{r}->{db};
  my $time = time;
  my $lastPurge = $db->getSettingValue('lastNoncePurge');

  # only purge if the last purge was never or over NONCE_PURGE_FREQUENCY ago
  if ( !defined($lastPurge) || ( $time - $lastPurge > NONCE_PURGE_FREQUENCY ) ) {
    my @userIDs = $db->listKeys();
    my @Keys = $db->getKeys(@userIDs);

    # Delete any "nonce" keys that are older than NONCE_LIFETIME
    foreach my $Key (@Keys) {
      if ($Key->key eq "nonce" && ($time-$Key->timestamp > NONCE_LIFETIME)) {
	$db->deleteKey($Key->user_id);
      }
    }

    $db->setSettingValue('lastNoncePurge',$time);
  }

}

1;

