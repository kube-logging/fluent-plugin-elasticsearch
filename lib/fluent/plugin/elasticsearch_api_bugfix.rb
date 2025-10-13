# Elasticsearch API 9.x Compatibility Patch
# 
# Fixes crashes in elasticsearch-api gem 9.1.2 when connecting to ES 7.x/8.x servers.
# 
# Bug: The gem expects ES 9 headers and crashes with NoMethodError when they're nil
#
# This patch is only needed if using elasticsearch gem 9.x
# Not needed if using elasticsearch gem 7.x or 8.x

require 'elasticsearch/api'

module Elasticsearch
  module API
    module Utils
      class << self
        if method_defined?(:update_ndjson_headers!)
          alias_method :original_update_ndjson_headers!, :update_ndjson_headers!
          
          def update_ndjson_headers!(headers, client_headers)
            return headers unless client_headers.is_a?(Hash)
            
            current_content = client_headers.keys.find { |c| c.to_s.match?(/content[-_]?type/i) }
            return headers unless current_content
            
            content_value = client_headers[current_content]
            return headers unless content_value
            
            # ES 7/8 compatibility: Only process ES9-specific headers
            # If no "compatible-with" present, this is ES 7/8 format
            return headers unless content_value.to_s.include?('compatible-with')
            
            # ES 9 detected, safe to call original
            original_update_ndjson_headers!(headers, client_headers)
          rescue StandardError => e
            warn "[elasticsearch-api-compat] Failed to update headers: #{e.class} - #{e.message}"
            headers
          end
        end
      end
    end
  end
end
