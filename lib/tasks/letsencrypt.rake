require 'open-uri'
require 'openssl'
require 'acme-client'
require 'platform-api'

namespace :letsencrypt do

  desc 'Renew your LetsEncrypt certificate'
  task :renew do
    # Check configuration looks OK
    abort "letsencrypt-rails-heroku is configured incorrectly. Are you missing an environment variable or other configuration? You should have a heroku_token, heroku_app, acmp_email and acme_domain configured either via a `Letsencrypt.configure` block in an initializer or as environment variables." unless Letsencrypt.configuration.valid?

    # Set up Heroku client
    heroku = PlatformAPI.connect_oauth Letsencrypt.configuration.heroku_token
    heroku_app = Letsencrypt.configuration.heroku_app

    # Create a private key
    print "Creating account key..."
    private_key = OpenSSL::PKey::RSA.new(4096)
    puts "Done!"

    client = Acme::Client.new(private_key: private_key, endpoint: Letsencrypt.configuration.acme_endpoint, connection_options: { request: { open_timeout: 5, timeout: 8 } })

    print "Registering with LetsEncrypt..."
    registration = client.register(contact: "mailto:#{Letsencrypt.configuration.acme_email}")

    registration.agree_terms
    puts "Done!"

    # set up connection to post challenge reponse to the app
    if ENV["LETSENCRYPT_CHALLENGE_SERVER"].nil? || ENV["LETSENCRYPT_CHALLENGE_SERVER"].strip.length == 0
      abort "Error: LETSENCRYPT_CHALLENGE_SERVER not set!"
    end
    connection = Faraday.new(:url => ENV["LETSENCRYPT_CHALLENGE_SERVER"]) do |faraday|
      faraday.request  :url_encoded             # form-encode POST params
      # faraday.response :logger                  # log requests to STDOUT
      faraday.adapter  Faraday.default_adapter  # make requests with Net::HTTP
    end

    domains = Letsencrypt.configuration.acme_domain.split(',').map(&:strip)
    nr_domains=domains.length
    domains.each_with_index do |domain, index|
      puts "Performing verification for #{domain} (#{index+1}/#{nr_domains}):"

      authorization = client.authorize(domain: domain)
      challenge = authorization.http01

      puts "Setting config vars on Heroku..."
      puts "post: challenge_response=#{challenge.file_content}"
      connection.post '/acme-challenge-response', { :challenge_response => challenge.file_content }
      puts "Done!"

      print "Sending LetsEncrypt request verification..."
      # Once you are ready to serve the confirmation request you can proceed.
      challenge.request_verification # => true
      challenge.verify_status # => 'pending'
      puts "Done!"

      print "Giving LetsEncrypt some time to verify..."
      sleep(13)
      puts "Done!"

      unless challenge.verify_status == 'valid'
        puts "Problem verifying challenge."
        abort "Status: #{challenge.verify_status}, Error: #{challenge.error}"
      end
      puts ""
    end

    # Create CSR
    csr = Acme::Client::CertificateRequest.new(names: domains)

    # Get certificate
    certificate = client.new_certificate(csr) # => #<Acme::Client::Certificate ....>

    # Send certificates to Heroku via API

    # First check for existing certificates:
    certificates = heroku.sni_endpoint.list(heroku_app)

    begin
      if certificates.any?
        print "Updating existing certificate #{certificates[0]['name']}..."
        heroku.sni_endpoint.update(heroku_app, certificates[0]['name'], {
          certificate_chain: certificate.fullchain_to_pem,
          private_key: certificate.request.private_key.to_pem
        })
        puts "Done!"
      else
        print "Adding new certificate..."
        heroku.sni_endpoint.create(heroku_app, {
          certificate_chain: certificate.fullchain_to_pem,
          private_key: certificate.request.private_key.to_pem
        })
        puts "Done!"
      end
    rescue Excon::Error::UnprocessableEntity => e
      warn "Error adding certificate to Heroku. Response from Heroku’s API follows:"
      abort e.response.body
    end
  end
end
