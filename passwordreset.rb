# The following gems are required
require 'rubygems'
require 'sinatra'
require 'data_mapper'
require 'digest/sha1'
require 'net/smtp'
require 'onetime/api'
require 'net/ssh'
require "ldap"
require 'base64'


enable :sessions

# Generate a keyhash for the random password
class KeyGenerator
    def self.generate(length = 10)
        Digest::SHA1.hexdigest(Time.now.to_s + rand(12341234).to_s)[1..length]
    end
end

# Setup DataMapper class with sqlite database
DataMapper::setup(:default, "sqlite3://#{Dir.pwd}/passwordreset.db")

class AuthExchange
    include DataMapper::Resource
    property :id, Serial
    property :username, Text, :required => true
    property :email, Text, :required => true
    property :keyhash, Text
    property :url, Text
    property :metaurl, Text
    property :complete, Boolean, :required => true, :default => false
    property :created_at, DateTime
    property :expires_at, DateTime
end

DataMapper.finalize.auto_upgrade!

# Some helpers to enable basic auth for protected pages
helpers do

    include Rack::Utils
    alias_method :h, :escape_html

    def protected!
        unless authorized?
            response['WWW-Authenticate'] = %(Basic realm="Restricted Area")
            throw(:halt, [401, "Not authorized\n"])
        end
    end

    def authorized?
        @auth ||=  Rack::Auth::Basic::Request.new(request.env)
        @auth.provided? && @auth.basic? && @auth.credentials && @auth.credentials == ['admin', 'admin']
    end

end

# Use ssh and smbldap-passwd to reset the passwords (could also work for non-ldap by changing the exec)
def sshpassword
sshhost = ''
sshuser = ''

    Net::SSH.start(sshhost, sshuser) do |ssh|
        ssh.open_channel do |channel|
            channel.on_request "exit-status" do |channel, data|
                $exit_status = data.read_long
            end
        channel.request_pty do |channel, success|
            channel.exec("smbldap-passwd #{@authex.username}")  # sshuser should be root
            if success
                channel.on_data do |channel, data|
                channel.send_data("#{@newpasswd}\n")
                sleep 0.1
            end
            else
                puts "Password change FAILED!!"
            end
        end
        channel.wait
        puts "Password change SUCCESS!!" if $exit_status == 0
     end
  end

end

# Use ldap binding to reset the password, make sure to fill in required variables
def ldappassword

$HOST = ''
$PORT = LDAP::LDAP_PORT
$SSLPORT = LDAP::LDAPS_PORT
base = 'dc=, dc='
ldapadmin = 'cn=, dc=, dc='
ldapadminpass = ''
scope = LDAP::LDAP_SCOPE_SUBTREE
attrs = ['sn', 'cn']

#hash the password for ldap change
e_password = "{SHA}" + Base64.encode64(Digest::SHA1.digest(@newpasswd)).chomp

conn = LDAP::Conn.new($HOST, $PORT)
reset = [
    LDAP.mod(LDAP::LDAP_MOD_REPLACE, "userPassword", [e_password]),
]

    conn.bind(ldapadmin,ldapadminpass)
    begin
            conn.search(base, scope, "uid=#{@authex.username}", attrs) { |entry|
            $USERDN = entry.dn
        }
        rescue LDAP::ResultError
        conn.perror("search")
        exit
    end

    begin
        conn.modify("#{$USERDN}", reset)
        puts $USERDN
        rescue LDAP::ResultError => msg
        puts "Can't change password: " + msg
        exit 0
        rescue LDAP::Error => errcode
        puts "Can't change password: " + LDAP.err2string(errcode)
        exit 0
    end



end

# Setup smtp information to mail results to user
def mailtome
    maildomain = ''
    fromaddr = ''
    frompasswd = ''
    mailserver = ''
    mailport = 
    mailname = @authex.username
    useremail = @authex.email
    mailhash = @authex.keyhash
    msg = "Subject: Password Reset Request
From:  Password Reset <passwordreset@placeholder.com>
To: #{mailname} <#{useremail}>
MIME-Version: 1.0
Content-type: text/html
Someone has requested a password reset for username <b>#{mailname}</b> at this email address.<br>
if it was you:<br>
<a href=\"#{request.url.gsub(/done/,'confirm')}/#{mailhash}\">Click here to confirm!</a><p>

If not you can ignore this request and the password reset request will expire in 10 minutes<p>
Regards,<br>
Your Admin."
    smtp = Net::SMTP.new mailserver, mailport
        smtp.enable_starttls
        smtp.start(maildomain, fromaddr, frompasswd, :login) do
        smtp.send_message(msg, fromaddr, useremail)
    end
end

# Setup onetimesecret mojo
def ots
otsusername = ''
otsapikey = ''

api = Onetime::API.new otsusername, otsapikey
    options = {
        :secret => @newpasswd,
        :ttl => 7200
    }
    ret = api.post '/share', options
    @authex.metaurl = "https://onetimesecret.com/private/#{ret['metadata_key']}"
    @authex.url = "https://onetimesecret.com/secret/#{ret['secret_key']}"
    @authex.save
end

# Define sinatra pages


get '/' do
    @title = 'Reset Password Request'
    erb :home
end

post '/' do
    a = AuthExchange.new
    a.username = params[:username]
    a.email = params[:username]+"@placeholder.com" 
    a.keyhash = KeyGenerator.generate
    a.created_at = Time.now
    a.expires_at = Time.now + 600
    a.save
    session[:number] = a.id
    redirect to '/done'
end

get '/done' do
    @authex = AuthExchange.get(session[:number])
    @title = "done"
    mailtome
    erb :done
end

get '/all' do
    protected!
    @title = 'all'
    @authex = AuthExchange.all :order => :id.desc
    erb :all
end

get '/confirm/:keyhash' do
    @title = 'confirm'
    @authex = AuthExchange.first(:keyhash => params[:keyhash])
    if @authex.expires_at < DateTime.now
        redirect '/expired'
    end
    if @authex.complete
        redirect '/complete'
    end
    erb :confirm
end

post '/confirm/:keyhash' do
    @authex = AuthExchange.first(:keyhash => params[:keyhash])
    @title = 'sent'
    if @authex.expires_at < DateTime.now
        redirect '/expired'
    end
    if @authex.complete
        redirect '/complete'
    end
    if params[:myPasswd]==''
        @newpasswd = rand(36**10).to_s(36)
    else
        @newpasswd = params[:myPasswd]
    end
# Use either ldappassword or sshpassword method to do direct ldap password reset, or via samba-passwd    
    #ldappassword
    sshpassword    
    ots
    @authex.complete = true
    @authex.save
    erb :sent
end

get '/expired' do
    @title = 'expired'
    erb :expired
end

get '/complete' do
    @title = 'complete'
    erb :complete
end

get '/:id' do
    protected!
    @authex = AuthExchange.get params[:id]
    @title = "requested"
    erb :show
end
