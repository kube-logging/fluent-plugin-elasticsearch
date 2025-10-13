# Compat

## Mixed Elasticsearch Version Environments

### Compatibility Matrix

| Elasticsearch Gem | ES 7.x Server | ES 8.x Server | ES 9.x Server |
|-------------------|---------------|---------------|---------------|
| gem 7.17.x        | ✅ Works      | ✅ Works      | ❌ No         |
| gem 8.15.x        | ✅ Works      | ✅ Works      | ❌ No         |
| gem 9.1.x + patch | ✅ With config| ✅ With config| ✅ Works      |

### Configuration Options

#### force_content_type

Type: String
Default: nil (auto-detect)
Valid values: "application/json", "application/x-ndjson"
Manually override the Content-Type header. Required when using elasticsearch gem 9.x with ES 7.x or 8.x servers.

```ruby
<match **>
  @type elasticsearch
  force_content_type application/json
</match>
```

#### ignore_version_content_type_mismatch

Type: Bool
Default: false
Automatically fallback to application/json if Content-Type version mismatch occurs. Enables seamless operation across mixed ES 7/8/9 environments.

Example:

```ruby
<match **>
  @type elasticsearch
  force_content_type application/json
  ignore_version_content_type_mismath true
</match>
```

### Recommended Configuration

#### For ES 7/8 environments (Recommended)

Use elasticsearch gem 8.x - works with both versions, no configuration needed:

```ruby
# Gemfile
gem 'elasticsearch', '~> 8.15.0'

# fluent.conf
<match **>
  @type elasticsearch
  hosts es7:9200,es8:9200
  # No special config needed!
</match>
```

#### For gem 9.x with ES 7/8 (Not recommended, but supported)

```ruby
# Gemfile
gem 'elasticsearch', '~> 9.1.0'

# fluent.conf
<match **>
  @type elasticsearch
  hosts es7:9200,es8:9200
  
  # REQUIRED: Force compatible content type
  force_content_type application/json
</match>
```
