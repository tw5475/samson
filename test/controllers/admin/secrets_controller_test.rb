# frozen_string_literal: true
require_relative '../../test_helper'

SingleCov.covered!

describe Admin::SecretsController do
  def create_global
    create_secret 'production/global/pod2/foo'
  end

  let(:secret) { create_secret 'production/foo/pod2/some_key' }
  let(:other_project) do
    Project.any_instance.stubs(:valid_repository_url).returns(true)
    Project.create!(name: 'Z', repository_url: 'Z')
  end
  let(:attributes) do
    {
      environment_permalink: 'production',
      project_permalink: 'foo',
      deploy_group_permalink: 'pod2',
      key: 'hi',
      value: 'secret',
      comment: 'hello',
      visible: false
    }
  end

  as_a_viewer do
    unauthorized :get, :index
    unauthorized :get, :new
  end

  as_a_project_deployer do
    unauthorized :post, :create, secret: {
      environment_permalink: 'production',
      project_permalink: 'foo',
      deploy_group_permalink: 'group',
      key: 'bar'
    }

    describe '#index' do
      before { create_global }

      it 'renders template without secret values' do
        get :index
        assert_template :index
        assigns[:secret_keys].size.must_equal 1
        response.body.wont_include secret.value
      end

      it 'can filter' do
        create_secret 'production/global/pod2/bar'
        get :index, params: {search: {query: 'bar'}}
        assert_template :index
        assigns[:secret_keys].must_equal ['production/global/pod2/bar']
      end

      it 'raises when vault server is broken' do
        SecretStorage.expects(:keys).raises(Samson::Secrets::BackendError.new('this is my error'))
        get :index
        assert flash[:error]
      end
    end

    describe "#new" do
      it "renders" do
        get :new
        assert_template :show
      end
    end

    describe '#show' do
      it "is unauthrized" do
        get :show, params: {id: secret}
        assert_response :unauthorized
      end
    end

    describe '#update' do
      it "is unauthrized" do
        put :update, params: {id: secret, secret: {value: 'xxx'}}
        assert_response :unauthorized
      end
    end

    describe "#destroy" do
      it "is unauthorized" do
        delete :destroy, params: {id: secret.id}
        assert_response :unauthorized
      end
    end
  end

  as_a_deployer do
    describe '#index' do
      it 'renders template' do
        get :index
        assert_template :index
      end
    end
  end

  as_a_project_admin do
    describe '#create' do
      it 'creates a secret' do
        post :create, params: {secret: attributes.merge(visible: true)}
        flash[:notice].wont_be_nil
        assert_redirected_to admin_secrets_path
        secret = SecretStorage::DbBackend::Secret.find('production/foo/pod2/hi')
        secret.updater_id.must_equal user.id
        secret.creator_id.must_equal user.id
        secret.visible.must_equal true
        secret.comment.must_equal 'hello'
      end

      it "redirects to new form when user wants to create another secret" do
        post :create, params: {secret: attributes, commit: Admin::SecretsController::ADD_MORE}
        flash[:notice].wont_be_nil
        assert_redirected_to "/admin/secrets/new?#{{secret: attributes.except(:value)}.to_query}"
      end

      it 'renders and sets the flash when invalid' do
        attributes[:key] = ''
        post :create, params: {secret: attributes}
        assert flash[:error]
        assert_template :show
      end

      it "is not authorized to create global secrets" do
        attributes[:project_permalink] = 'global'
        post :create, params: {secret: attributes}
        assert_response :unauthorized
      end
    end

    describe '#show' do
      it 'renders for local secret as project-admin' do
        get :show, params: {id: secret}
        assert_template :show
        response.body.wont_include secret.value
      end

      it 'shows visible secerts' do
        secret.update_column(:visible, true)
        get :show, params: {id: secret}
        assert_template :show
        response.body.must_include secret.value
      end

      it 'renders with unfound users' do
        secret.update_column(:updater_id, 32232323)
        get :show, params: {id: secret}
        assert_template :show
        response.body.must_include "Unknown user id"
      end

      it "is unauthrized for global secret" do
        get :show, params: {id: create_global}
        assert_response :unauthorized
      end
    end

    describe '#update' do
      def attributes
        super.except(*SecretStorage::SECRET_KEYS_PARTS)
      end

      before do
        patch :update, params: {id: secret.id, secret: attributes}
      end

      it 'updates' do
        flash[:notice].wont_be_nil
        assert_redirected_to admin_secrets_path
        secret.reload
        secret.updater_id.must_equal user.id
        secret.creator_id.must_equal users(:admin).id
      end

      describe 'invalid' do
        def attributes
          super.merge(value: '')
        end

        it 'fails to update' do
          assert_template :show
          assert flash[:error]
        end
      end

      describe 'updating key' do
        def attributes
          super.merge(key: 'bar')
        end

        it "is not supported" do
          assert_redirected_to admin_secrets_path
          secret.reload.id.must_equal 'production/foo/pod2/some_key'
        end
      end

      describe 'showing a not owned project' do
        let(:secret) { create_secret "production/#{other_project.permalink}/foo/xxx" }

        it "is not allowed" do
          assert_response :unauthorized
        end
      end

      describe 'global' do
        let(:secret) { create_global }

        it "is unauthrized" do
          assert_response :unauthorized
        end
      end
    end

    describe "#destroy" do
      it "deletes project secret" do
        delete :destroy, params: {id: secret}
        assert_redirected_to admin_secrets_path
      end

      it "is unauthorized for global" do
        delete :destroy, params: {id: create_global}
        assert_response :unauthorized
      end
    end
  end

  as_a_admin do
    let(:secret) { create_global }

    describe '#create' do
      before do
        post :create, params: {secret: attributes}
      end

      it 'redirects and sets the flash' do
        flash[:notice].wont_be_nil
        assert_redirected_to admin_secrets_path
      end
    end

    describe '#show' do
      it "renders" do
        get :show, params: {id: secret.id}
        assert_template :show
      end

      it "renders with unknown project" do
        secret.update_column(:id, 'oops/bar')
        get :show, params: {id: secret.id}
        assert_template :show
      end
    end

    describe '#update' do
      it "updates" do
        put :update, params: {id: secret, secret: attributes.except(*SecretStorage::SECRET_KEYS_PARTS)}
        assert_redirected_to admin_secrets_path
      end
    end

    describe '#destroy' do
      it 'deletes and redirects' do
        delete :destroy, params: {id: secret.id}
        flash[:notice].wont_be_nil
        assert_redirected_to admin_secrets_path
        SecretStorage::DbBackend::Secret.exists?(secret.id).must_equal(false)
      end

      it "works with unknown project" do
        secret.update_column(:id, 'oops/bar')
        delete :destroy, params: {id: secret.id}
        flash[:notice].wont_be_nil
        assert_redirected_to admin_secrets_path
        SecretStorage::DbBackend::Secret.exists?(secret.id).must_equal(false)
      end
    end
  end
end
