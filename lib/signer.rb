require "nokogiri"
require "base64"
require "digest/sha1"
require "openssl"

require "signer/version"

class Signer
  attr_accessor :document, :cert, :private_key
  attr_writer :security_node, :security_token_id

  WSU_NAMESPACE = 'http://docs.oasis-open.org/wss/2004/01/oasis-200401-wss-wssecurity-utility-1.0.xsd'

  def initialize(document)
    self.document = Nokogiri::XML(document.to_s, &:noblanks)
  end

  def to_xml
    document.to_xml(:save_with => 0)
  end

  def security_token_id
    @security_token_id ||= "uuid-639b8970-7644-4f9e-9bc4-9c2e367808fc-1"
  end

  def security_node
    @security_node ||= document.xpath("//o:Security", "o" => "http://docs.oasis-open.org/wss/2004/01/oasis-200401-wss-wssecurity-secext-1.0.xsd").first
  end

  def canonicalize(node = document)
    node.canonicalize(Nokogiri::XML::XML_C14N_EXCLUSIVE_1_0, nil, nil) # The last argument should be exactly +nil+ to remove comments from result
  end

  # <Signature xmlns="http://www.w3.org/2000/09/xmldsig#">
  def signature_node
    node = document.xpath("//ds:Signature", "ds" => "http://www.w3.org/2000/09/xmldsig#").first
    unless node
      node = Nokogiri::XML::Node.new('Signature', document)
      node.default_namespace = 'http://www.w3.org/2000/09/xmldsig#'
      security_node.first_element_child.add_previous_sibling(node)
    end
    node
  end

  # <SignedInfo>
  #   <CanonicalizationMethod Algorithm="http://www.w3.org/2001/10/xml-exc-c14n#"/>
  #   <SignatureMethod Algorithm="http://www.w3.org/2000/09/xmldsig#rsa-sha1"/>
  #   ...
  # </SignedInfo>
  def signed_info_node
    node = signature_node.xpath("//ds:SignedInfo", "ds" => 'http://www.w3.org/2000/09/xmldsig#').first
    unless node
      node = Nokogiri::XML::Node.new('SignedInfo', document)
      signature_node.add_child(node)
      canonicalization_method_node = Nokogiri::XML::Node.new('CanonicalizationMethod', document)
      canonicalization_method_node['Algorithm'] = 'http://www.w3.org/2001/10/xml-exc-c14n#'
      node.add_child(canonicalization_method_node)
      signature_method_node = Nokogiri::XML::Node.new('SignatureMethod', document)
      signature_method_node['Algorithm'] = 'http://www.w3.org/2000/09/xmldsig#rsa-sha1'
      node.add_child(signature_method_node)
    end
    node
  end

  # <o:BinarySecurityToken u:Id="" ValueType="http://docs.oasis-open.org/wss/2004/01/oasis-200401-wss-x509-token-profile-1.0#X509v3" EncodingType="http://docs.oasis-open.org/wss/2004/01/oasis-200401-wss-soap-message-security-1.0#Base64Binary">
  #   ...
  # </o:BinarySecurityToken>
  # <SignedInfo>
  #   ...
  # </SignedInfo>
  # <KeyInfo>
  #   <o:SecurityTokenReference>
  #     <o:Reference ValueType="http://docs.oasis-open.org/wss/2004/01/oasis-200401-wss-x509-token-profile-1.0#X509v3" URI="#uuid-639b8970-7644-4f9e-9bc4-9c2e367808fc-1"/>
  #   </o:SecurityTokenReference>
  # </KeyInfo>
  def binary_security_token_node
    node = document.xpath("//o:BinarySecurityToken", "o" => "http://docs.oasis-open.org/wss/2004/01/oasis-200401-wss-wssecurity-secext-1.0.xsd").first
    unless node
      node = Nokogiri::XML::Node.new('BinarySecurityToken', document)
      node['ValueType']    = 'http://docs.oasis-open.org/wss/2004/01/oasis-200401-wss-x509-token-profile-1.0#X509v3'
      node['EncodingType'] = 'http://docs.oasis-open.org/wss/2004/01/oasis-200401-wss-soap-message-security-1.0#Base64Binary'
      node.content = Base64.encode64(cert.to_der).gsub("\n", '')
      signature_node.add_previous_sibling(node)
      wsu_ns = namespace_prefix(node, WSU_NAMESPACE, 'wsu')
      node["#{wsu_ns}:Id"] = security_token_id
      key_info_node = Nokogiri::XML::Node.new('KeyInfo', document)
      security_token_reference_node = Nokogiri::XML::Node.new('o:SecurityTokenReference', document)
      key_info_node.add_child(security_token_reference_node)
      reference_node = Nokogiri::XML::Node.new('o:Reference', document)
      reference_node['ValueType'] = 'http://docs.oasis-open.org/wss/2004/01/oasis-200401-wss-x509-token-profile-1.0#X509v3'
      reference_node['URI'] = "##{security_token_id}"
      security_token_reference_node.add_child(reference_node)
      signed_info_node.add_next_sibling(key_info_node)
    end
    node
  end

  # <ds:KeyInfo Id="KeyId-363DE641F62F9F5FF31402068320382449">
  #   <wsse:SecurityTokenReference wsu:Id="STRId-363DE641F62F9F5FF31402068320382450" xmlns:wsse="http://docs.oasis-open.org/wss/2004/01/oasis-200401-wss-wssecurity-secext-1.0.xsd" xmlns:wsu="http://docs.oasis-open.org/wss/2004/01/oasis-200401-wss-wssecurity-utility-1.0.xsd">
  #     <ds:X509Data>
  #       <ds:X509IssuerSerial>
  #         <ds:X509IssuerName>CN=Google Internet Authority G2,O=Google Inc,C=US</ds:X509IssuerName>
  #         <ds:X509SerialNumber>1387084050634530550</ds:X509SerialNumber>
  #       </ds:X509IssuerSerial>
  #     </ds:X509Data>
  #   </wsse:SecurityTokenReference>
  # </ds:KeyInfo>
  def x509_data_node
    issuer_name_node   = Nokogiri::XML::Node.new('X509IssuerName', document)
    issuer_name_node.content = cert.subject.to_s.split("\/").delete_if{|e| e==""}.reverse.join(",")

    issuer_number_node = Nokogiri::XML::Node.new('X509SerialNumber', document)
    issuer_number_node.content = cert.serial

    issuer_serial_node = Nokogiri::XML::Node.new('X509IssuerSerial', document)
    issuer_serial_node.add_child(issuer_name_node)
    issuer_serial_node.add_child(issuer_number_node)

    data_node          = Nokogiri::XML::Node.new('X509Data', document)
    data_node.add_child(issuer_serial_node)

    security_token_reference_node = Nokogiri::XML::Node.new('o:SecurityTokenReference', document)
    security_token_reference_node.add_child(data_node)


    key_info_node      = Nokogiri::XML::Node.new('KeyInfo', document)
    key_info_node.add_child(security_token_reference_node)

    signed_info_node.add_next_sibling(key_info_node)

    data_node
  end

  # <Reference URI="#_0">
  #   <Transforms>
  #     <Transform Algorithm="http://www.w3.org/2001/10/xml-exc-c14n#"/>
  #   </Transforms>
  #   <DigestMethod Algorithm="http://www.w3.org/2000/09/xmldsig#sha1"/>
  #   <DigestValue>aeqXriJuUCk4tPNPAGDXGqHj6ao=</DigestValue>
  # </Reference>
  def digest!(target_node, options = {})
    wsu_ns = namespace_prefix(target_node, WSU_NAMESPACE)
    current_id = target_node["#{wsu_ns}:Id"]  if wsu_ns
    id = options[:id] || current_id || "_#{Digest::SHA1.hexdigest(target_node.to_s)}"
    if id.to_s.size > 0
      wsu_ns ||= namespace_prefix(target_node, WSU_NAMESPACE, 'wsu')
      target_node["#{wsu_ns}:Id"] = id.to_s
    end
    what_to_digest = nil
    if options[:only_sign_entire_headers_and_body]
      # need to find entire header or body to digest
      tmpnode = target_node
      while tmpnode.name.downcase != 'header' and tmpnode.name.downcase != 'body'
        tmpnode = tmpnode.parent
      end
      what_to_digest = tmpnode
    else
      what_to_digest = target_node
    end
    target_canon = canonicalize(what_to_digest)
    target_digest = Base64.encode64(OpenSSL::Digest::SHA1.digest(target_canon)).strip

    reference_node = Nokogiri::XML::Node.new('Reference', document)
    reference_node['URI'] = id.to_s.size > 0 ? "##{id}" : ""
    signed_info_node.add_child(reference_node)

    transforms_node = Nokogiri::XML::Node.new('Transforms', document)
    reference_node.add_child(transforms_node)

    transform_node = Nokogiri::XML::Node.new('Transform', document)
    if options[:enveloped]
      transform_node['Algorithm'] = 'http://www.w3.org/2000/09/xmldsig#enveloped-signature'
    else
      transform_node['Algorithm'] = 'http://www.w3.org/2001/10/xml-exc-c14n#'
    end
    transforms_node.add_child(transform_node)

    digest_method_node = Nokogiri::XML::Node.new('DigestMethod', document)
    digest_method_node['Algorithm'] = 'http://www.w3.org/2000/09/xmldsig#sha1'
    reference_node.add_child(digest_method_node)

    digest_value_node = Nokogiri::XML::Node.new('DigestValue', document)
    digest_value_node.content = target_digest
    reference_node.add_child(digest_value_node)
    self
  end

  # <SignatureValue>...</SignatureValue>
  def sign!(options = {})
    if options[:security_token]
      binary_security_token_node
    end

    if options[:issuer_serial]
      x509_data_node
    end

    signed_info_canon = canonicalize(signed_info_node)

    signature = private_key.sign(OpenSSL::Digest::SHA1.new, signed_info_canon)
    signature_value_digest = Base64.encode64(signature).gsub("\n", '')

    signature_value_node = Nokogiri::XML::Node.new('SignatureValue', document)
    signature_value_node.content = signature_value_digest
    signed_info_node.add_next_sibling(signature_value_node)
    self
  end

  protected

  ##
  # Searches in namespaces, defined on +target_node+ or its ancestors,
  # for the +namespace+ with given URI and returns its prefix.
  #
  # If there is no such namespace and +desired_prefix+ is specified,
  # adds such a namespace to +target_node+ with +desired_prefix+

  def namespace_prefix(target_node, namespace, desired_prefix = nil)
    ns = target_node.namespaces.key(namespace)
    if ns
      ns.match(/(?:xmlns:)?(.*)/) && $1
    elsif desired_prefix
      target_node.add_namespace_definition(desired_prefix, namespace)
      desired_prefix
    end
  end

end
