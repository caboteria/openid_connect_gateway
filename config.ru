require 'rack/reverse_proxy'
require 'omniauth/builder'
require 'omniauth_openid_connect'
require 'rack/session/cookie'
require 'pry'
require 'warden'
require 'warden_omniauth'
require 'yaml'

SESSION_KEY      = 'rack.session'
class WardenOmniAuth
def call(env)

    request = Rack::Request.new(env)
    prefix = OmniAuth::Configuration.instance.path_prefix
    if request.path =~ /^#{prefix}\/(.+?)\/callback$/i
      strategy_name = $1
      strategy = Warden::Strategies._strategies.keys.detect{|k| k.to_s == "omni_#{strategy_name}"}

      if !strategy
        Rack::Response.new("Unknown Handler", 401).finish
      else
        # Warden needs to use a hashie for looking up scope
        # and strategy names
        session = env[SESSION_KEY]
        scope = session[SCOPE_KEY]
        if scope.nil? || scope.to_s.length < 100 # have to protect against symbols :(. need a hashie
          args = [strategy]
          args << {:scope => scope.to_sym} if scope
          response = Rack::Response.new
          if env['warden'].authenticate? *args
            response.redirect(session["original_url"] || "/")
            response.finish
          else
            auth_path = request.path.gsub(/\/callback$/, "")
            response.redirect(auth_path)
            response.finish
          end
        else
          Rack::Response.new("Bad Session", 400).finish
        end
      end
    else
      @app.call(env)
    end
  end

end


Warden::Manager.serialize_into_session do |user|
  user
end

Warden::Manager.serialize_from_session do |user|
  user
end

# Last thing in the stack if the reverse proxy doesn't handle the url
# also allows to logout 
app = lambda do |e|
  
  request = Rack::Request.new(e)
  if request.path =~ /logout/
    e['warden'].logout
    r = Rack::Response.new
    r.redirect("/")
    r.finish
  else
    request = Rack::Request.new(e)
    session = e[SESSION_KEY]
	session["original_url"] = request.path
    e['warden'].authenticate!
    Rack::Response.new(e['warden'].user.inspect).finish
  end
end

# simple failure app
failure = lambda{|e| Rack::Resposne.new("Can't login", 401).finish }


# need some cookies to store info in
use Rack::Session::Cookie


# Get warden in the stack so we can do authentication.  Warden will take care of the redirec
# back to the original url requested once authentication takes place. 
use Warden::Manager do |config|
  config.failure_app = failure
  config.default_strategies :omni_openid_connect
end


# Override what the ReverseProxy code does as a default behaviour so it can check to see if the 
# user is authenticated yet and ignore the request if it is not
module Rack
  class ReverseProxy
    alias :old_call :call
    def call(env)
     
      return @app.call(env) unless (env['warden'] && env['warden'].authenticated?)
      old_call(env)
    end
     
  end
end

# get the ReverseProxy on the stack.  Configuration is done in a separate file so people dont need 
# top go trudging throuch this to configure the redirects
use Rack::ReverseProxy do 
  instance_eval  File.new('proxy_config.rb').read
 
end

# Setup the Omniauth stack and configure the openid connect provider.  Provider config is in a separate file
use OmniAuth::Builder do

  config = YAML.load(File.new("openid.yml"))
  provider :openid_connect , config['host'], config['client_id'], config['client_secret'],config['additional_properties']
                                                                    
end


# Wrap the Omniauth stuff in a warden strategy so it's easy for warden to use it
use WardenOmniAuth do |config|
  #config.redirect_after_callback = "/redirect/path" # default "/"
end

# need to tell WardenOmniAuth about the openid_connect provider
WardenOmniAuth.setup_strategies("openid_connect")

# this defines what the user will look like after login and what warden will expect the user to be.  Right now
# this just returns the omniauth auth_hash that is passed in
WardenOmniAuth.on_callback do |omni_user|
omni_user
end

# run the stack
run app