module IosDeployKit
  # This class takes care of handling the whole deployment process
  # This includes:
  # 
  # - Parsing the Deliverfile
  # - Temporary storing all the information got from the file, until the file finished executing
  # - Triggering the upload process itself
  class Deliverer
    # DeliverUnitTestsError is triggered, when the unit tests of the given block failed.
    class DeliverUnitTestsError < StandardError
    end
    
    # General

    # @return (IosDeployKit::App) The App that is currently being edited.
    attr_accessor :app
    # @return (IosDeployKit::Deliverfile::Deliverfile) A reference
    #  to the Deliverfile which is currently being used.
    attr_accessor :deliver_file

    # @return (Hash) All the updated/new information we got from the Deliverfile. 
    #  is used to store the deploy information until the Deliverfile finished running.
    attr_accessor :deploy_information

    module ValKey
      APP_IDENTIFIER = :app_identifier
      APPLE_ID = :apple_id
      APP_VERSION = :version
      IPA = :ipa
      DESCRIPTION = :description
      TITLE = :title
      CHANGELOG = :changelog
      SUPPORT_URL = :support_url
      PRIVACY_URL = :privacy_url
      MARKETING_URL = :marketing_url
      KEYWORDS = :keywords
      SCREENSHOTS_PATH = :screenshots_path
      DEFAULT_LANGUAGE = :default_language
    end

    module AllBlocks
      UNIT_TESTS = :unit_tests
      SUCCESS = :success
      ERROR = :error
    end

    
    # Start a new deployment process based on the given Deliverfile
    # @param (String) path The path to the Deliverfile.
    # @param (Hash) hash You can pass a hash instead of a path to basically
    #  give all the information required (see {Deliverer::ValKey} for available options)
    def initialize(path = nil, hash = nil)
      @deploy_information = {}

      if hash
        hash.each do |key, value|
          # we still call this interface to verify the inputs correctly
          set_new_value(key, value)
        end

        finished_executing_deliver_file
      else
        @deliver_file = IosDeployKit::Deliverfile::Deliverfile.new(self, path)
      end


      # Do not put code here...
    end

    # This method is internally called from the Deliverfile DSL
    # to set a value for a given key. This method will also verify if 
    # the key is valid.
    def set_new_value(key, value)
      unless self.class.all_available_keys_to_set.include?key
        raise "Invalid key '#{key}', must be contained in Deliverer::ValKey."
      end

      if @deploy_information[key]      
        Helper.log.warn("You already set a value for key '#{key}'. Overwriting value '#{value}' with new value.")
      end

      @deploy_information[key] = value
    end

    # Sets a new block for a specific key
    def set_new_block(key, block)
      @active_blocks ||= {}
      @active_blocks[key] = block
    end

    # An array of all available options to be set a deployment_information.
    # 
    # Is used to verify user inputs
    # @return (Hash) The array of symbols
    def self.all_available_keys_to_set
      Deliverer::ValKey.constants.collect { |a| Deliverer::ValKey.const_get(a) }
    end

    # An array of all available blocks to be set for a deployment
    # 
    # Is used to verify user inputs
    # @return (Hash) The array of symbols
    def self.all_available_blocks_to_set
      Deliverer::AllBlocks.constants.collect { |a| Deliverer::AllBlocks.const_get(a) }
    end


    # This method will take care of the actual deployment process, after we 
    # received all information from the Deliverfile. 
    # 
    # This method will be called from the {IosDeployKit::Deliverfile} after
    # it is finished executing the Ruby script.
    def finished_executing_deliver_file
      begin
        @active_blocks ||= {}

        app_version = @deploy_information[ValKey::APP_VERSION]
        app_identifier = @deploy_information[ValKey::APP_IDENTIFIER]
        apple_id = @deploy_information[ValKey::APPLE_ID]

        errors = IosDeployKit::Deliverfile::Deliverfile

        # Verify or complete the IPA information (app identifier and app version)
        if @deploy_information[ValKey::IPA]

          @ipa = IosDeployKit::IpaUploader.new(IosDeployKit::App.new, '/tmp/', @deploy_information[ValKey::IPA])

          # We are able to fetch some metadata directly from the ipa file
          # If they were also given in the Deliverfile, we will compare the values

          if app_identifier
            if app_identifier != @ipa.fetch_app_identifier
              raise errors::DeliverfileDSLError.new("App Identifier of IPA does not match with the given one (#{app_identifier} != #{@ipa.fetch_app_identifier})")
            end
          else
            app_identifier = @ipa.fetch_app_identifier
          end

          if app_version
            if app_version != @ipa.fetch_app_version
              raise errors::DeliverfileDSLError.new("App Version of IPA does not match with the given one (#{app_version} != #{@ipa.fetch_app_version})")
            end
          else
            app_version = @ipa.fetch_app_version
          end        
        end

        
        raise errors::DeliverfileDSLError.new(errors::MISSING_APP_IDENTIFIER_MESSAGE) unless app_identifier
        raise errors::DeliverfileDSLError.new(errors::MISSING_VERSION_NUMBER_MESSAGE) unless app_version

        Helper.log.info("Got all information needed to deploy a the update '#{app_version}' for app '#{app_identifier}'")

        @app = IosDeployKit::App.new(app_identifier: app_identifier,
                                           apple_id: apple_id)

        @app.metadata.verify_version(app_version)

        if @active_blocks[:unit_tests]
          result = @active_blocks[:unit_tests].call
          if result != true and (result || 0).to_i != 1
            raise DeliverUnitTestsError.new("Unit tests failed. Got result: '#{result}'. Need 'true' or 1 to succeed.")
          end
        end

        # Now: set all the updated metadata. We can only do that
        # once the whole file is finished

        # Most important
        @app.metadata.update_title(@deploy_information[ValKey::TITLE]) if @deploy_information[ValKey::TITLE]
        @app.metadata.update_description(@deploy_information[ValKey::DESCRIPTION]) if @deploy_information[ValKey::DESCRIPTION]

        # URLs
        @app.metadata.update_support_url(@deploy_information[ValKey::SUPPORT_URL]) if @deploy_information[ValKey::SUPPORT_URL]
        @app.metadata.update_changelog(@deploy_information[ValKey::CHANGELOG]) if @deploy_information[ValKey::CHANGELOG]
        @app.metadata.update_marketing_url(@deploy_information[ValKey::MARKETING_URL]) if @deploy_information[ValKey::MARKETING_URL]

        # App Keywords
        @app.metadata.update_keywords(@deploy_information[ValKey::KEYWORDS]) if @deploy_information[ValKey::KEYWORDS]

        # Screenshots
        screens_path = @deploy_information[ValKey::SCREENSHOTS_PATH]
        if screens_path
          if not @app.metadata.set_all_screenshots_from_path(screens_path)
            # This path does not contain folders for each language
            if screens_path.kind_of?String
              if @deploy_information[ValKey::DEFAULT_LANGUAGE]
                screens_path = { @deploy_information[ValKey::DEFAULT_LANGUAGE] => screens_path }
              else
                raise "You have to have folders for each language (e.g. en-US, de-DE) or provide a default language or provide a hash with one path for each language"
              end
            end
            @app.metadata.set_screenshots_for_each_language(screens_path)
          end
        end
        

        result = @app.metadata.upload!

        # IPA File
        # The IPA file has to be handles seperatly
        if @ipa
          @ipa.app = @app # we now have the resulting app
          @ipa.upload!
        end

        @active_blocks[:success].call if @active_blocks[:success]

      rescue Exception => ex
        if @active_blocks[:error]
          # Custom error handling, we just call this one
          @active_blocks[:error].call(ex)
        else
          # Re-Raise the exception
          raise ex
        end
      end
    end
  end
end