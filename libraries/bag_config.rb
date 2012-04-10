# This is a proxy object used within recipes
# to allow bag based attribute overrides
class NodeOverride
  # Access to actual node instance
  attr_accessor :node
  # Recipe this proxy instance is associated to
  attr_accessor :recipe

  # node:: Chef::Node
  # recipe:: Chef::Recipe
  # Create a new NodeOverride proxy
  def initialize(node, recipe)
    @node = node
    @recipe = recipe
  end

  # key:: Base key for access
  # Returns mapped key if mapping provided
  def base_key(key)
    node[:bag_config][:mapping][key] || key
  end

  # key:: base key accessing attributes
  # Returns data bag name if custom data bag is in use
  def data_bag_name(key)
    name = base_key(key)
    [key, base_key(key)].each do |k|
      if(node[:bag_config][:info][k] && node[:bag_config][:info][k][:bag])
        name = node[:bag_config][:info][k][:bag]
      end
    end
    name
  end

  # key:: base key accessing attributes
  # Returns data bag item name if custom data bag item name is in use
  def data_bag_item_name(key)
    name = "config_#{node.name.gsub('.', '_')}"
    [key, base_key(key)].each do |k|
      if(node[:bag_config][:info][k] && node[:bag_config][:info][k][:item])
        name = node[:bag_config][:info][k][:item]
      end
    end
    name
  end

  # key:: base key accessing attributes
  # Returns if the data bag item is encrypted
  def encrypted_data_bag_item?(key)
    encrypted = false
    [key, base_key(key)].each do |k|
      if(node[:bag_config][:info][k])
        encrypted = !!node[:bag_config][:info][k][:encrypted]
      end
    end
    encrypted
  end

  # key:: base key accessing attributes
  # Returns data bag item secret if applicable
  def data_bag_item_secret(key)
    secret = nil
    [key, base_key(key)].each do |k|
      if(node[:bag_config][:info][k] && node[:bag_config][:info][k][:secret])
        secret = node[:bag_config][:info][k][:secret]
        if(File.exists?(secret))
          secret = Chef::EncryptedDataBagItem.load_secret(secret)
        end
      end
    end
    secret
  end

  # key:: base key accessing attributes
  # Returns proper key to use for index based
  def data_bag_item(key)
    key = key.to_sym
    @@cached_items ||= {}
    begin
      if(@@cached_items[key].nil?)
        if(encrypted_data_bag_item?(key))
          @@cached_items[key] = Chef::EncryptedDataBagItem.load(
            data_bag_name(key),
            data_bag_item_name(key),
            data_bag_item_secret(key)
          )
        else
          @@cached_items[key] = Chef::DataBagItem.load(
            data_bag_name(key),
            data_bag_item_name(key)
          )
        end
      end
    rescue => e
      Chef::Log.debug("Failed to retrieve configuration data bag item (#{key}): #{e}")
      @@cached_items[key] = false
    end
    @@cached_items[key]
  end

  # key:: Attribute key
  # Returns attribute with bag overrides if applicable
  def [](key)
    key = key.to_sym
    @@lookup_cache = {}
    if(@@lookup_cache[key])
      @@lookup_cache[key]
    else
      val = data_bag_item(key)
      if(val)
        val.delete('id')
        atr = Chef::Node::Attribute.new(
          node.normal_attrs,
          node.default_attrs,
          Chef::Mixin::DeepMerge.merge(
            node.override_attrs,
            Mash.new(key => val.to_hash)
          ),
          node.automatic_attrs
        )
        res = atr[key]
      end
      @@lookup_cache[key] = res || node[key]
    end
  end

  # Provides proper proxy to Chef::Node instance
  def method_missing(symbol, *args)
    if(@node.respond_to?(symbol))
      @node.send(symbol, *args)
    else
      self[args.first]
    end
  end

end

module BagConfig

  # Override for #node method
  def override_node
    if(@_node_override.nil? || @_node_override.node != original_node)
      @_node_override = NodeOverride.new(original_node, self)
    end
    @_node_override
  end

  # Aliases around the #node based methods
  def self.included(base) # :nordoc:
    base.class_eval do
      alias_method :original_node, :node
      alias_method :node, :override_node
    end
  end

end

# Hook everything in
Chef::Recipe.send(:include, BagConfig)
::Erubis::Context.send(:include, BagConfig)
