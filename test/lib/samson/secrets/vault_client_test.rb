# frozen_string_literal: true
require_relative '../../../test_helper'

SingleCov.covered!

describe Samson::Secrets::VaultClient do
  include VaultRequestHelper

  # have 2 servers around so we can test multi-server logic
  before do
    server = Samson::Secrets::VaultServer.create!(name: 'pod1', address: 'http://vault-land.com', token: 'TOKEN2')
    deploy_groups(:pod1).update_column(:vault_server_id, server.id)
  end

  let(:client) { Samson::Secrets::VaultClient.new }

  describe ".client" do
    it "is cached" do
      Samson::Secrets::VaultClient.client.object_id.must_equal Samson::Secrets::VaultClient.client.object_id
    end
  end

  describe "#initialize" do
    let(:clients) { client.instance_variable_get(:@clients) }

    it "creates clients without certs" do
      refute clients.values.first.options.fetch(:ssl_cert_store)
    end

    it "adds certs when server has a ca_cert" do
      Samson::Secrets::VaultServer.update_all(ca_cert: File.read("#{fixture_path}/self-signed-test-cert.pem"))
      assert clients.values.first.options.fetch(:ssl_cert_store)
    end
  end

  describe "#read" do
    it "only reads from first server" do
      assert_vault_request :get, 'global/global/global/foo', body: {data: {foo: :bar}}.to_json do
        client.read('global/global/global/foo').class.must_equal(Vault::Secret)
      end
    end
  end

  describe "#write" do
    it "writes to all servers" do
      assert_vault_request :put, 'global/global/global/foo', times: 2 do
        client.write('global/global/global/foo', foo: :bar)
      end
    end
  end

  describe "#delete" do
    it "deletes from all servers" do
      assert_vault_request :delete, 'global/global/global/foo', times: 2 do
        client.delete('global/global/global/foo')
      end
    end
  end

  describe "#list" do
    it "combines lists from all servers" do
      assert_vault_request :get, '?list=true', body: {data: {keys: ['abc']}}.to_json, times: 2 do
        client.list('').must_equal ['abc']
      end
    end
  end

  describe "#clients" do
    it "scopes to matching server" do
      Samson::Secrets::VaultServer.last.update_column(:address, 'do-not-use')
      assert_vault_request :put, 'global/global/pod2/foo' do
        client.write('global/global/pod2/foo', foo: :bar)
      end
    end

    it "fails descriptively when not deploy group was found" do
      e = assert_raises(RuntimeError) do
        client.write('global/global/podoops/foo', foo: :bar)
      end
      e.message.must_equal "no deploy group with permalink podoops found"
    end
  end

  describe "#client" do
    it "finds correct client" do
      client.client(deploy_groups(:pod2)).options.fetch(:token).must_equal 'TOKEN'
    end

    it "fails descriptively when deploy group has no vault server associated" do
      deploy_groups(:pod2).update_column(:vault_server_id, nil)
      e = assert_raises(RuntimeError) { client.client(deploy_groups(:pod2)) }
      e.message.must_equal "deploy group pod2 has no vault server configured"
    end

    it "fails descriptively when vault client cannot be found" do
      client # trigger caching
      deploy_groups(:pod2).update_column(:vault_server_id, 123)
      e = assert_raises(RuntimeError) { client.client(deploy_groups(:pod2)) }
      e.message.must_equal "no vault server found with id 123"
    end
  end
end
