ldappasswordreset
=================

A ruby/sinatra based self-serve ldap password reset webapp using self-destruct 
messages with onetimesecret

** The following gems are required**
* rubygems
* sinatra
* data_mapper
* digest/sha1
* net/smtp
* onetime/api
* net/ssh
* ruby-ldap
* base64

**usage:**
`ruby passwordreset.rb`

Although ideally you probably want to use shotgun or an actual ruby webserver.

This will allow users to submit a request for password change, either with a
pre-defined password, or a randomly generated password. An email will be sent
to the user at a defined domain to confirm that they requested the password
reset. If the user is not confirmed the reset request will expire in 10 mins.
 Once the user is confirmed the supplied password will be used or a 
random password will be generated. This password will be reset either by
direct ldap binding or via smbldap passwd. If the user gets a random password
the random password will be sent to the user via a onetimesecret message.

DISCLAIMER: This was just an experiment to play with some new ideas and tech,
It should not be used in a production environment as it would need some 
serious work to ensure proper security. 
