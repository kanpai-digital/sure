# frozen_string_literal: true

require "test_helper"

class RevolutXItem::SyncerTest < ActiveSupport::TestCase
  setup do
    @item = revolut_x_items(:one)
    @item.revolut_x_accounts.destroy_all
  end

  test "fails the sync and asks for an update when credentials are missing" do
    item = revolut_x_items(:awaiting_api_key)
    sync = item.syncs.create!
    item.expects(:import_latest_revolut_x_data).never

    RevolutXItem::Syncer.new(item).perform_sync(sync)

    assert sync.reload.failed?
    assert item.reload.requires_update?
  end

  test "an authentication failure marks the item as needing an update" do
    sync = @item.syncs.create!
    @item.expects(:import_latest_revolut_x_data).raises(Provider::RevolutX::AuthenticationError, "bad key")

    assert_raises(Provider::RevolutX::AuthenticationError) do
      RevolutXItem::Syncer.new(@item).perform_sync(sync)
    end

    assert sync.reload.failed?
    assert @item.reload.requires_update?
  end

  test "a successful import restores good status and flags unlinked accounts for setup" do
    @item.update!(status: :requires_update)
    sync = @item.syncs.create!
    @item.revolut_x_accounts.create!(name: "Revolut X", account_id: "default", account_type: "exchange", currency: "USD")
    @item.expects(:import_latest_revolut_x_data).returns(success: true)
    @item.expects(:process_accounts).never

    RevolutXItem::Syncer.new(@item).perform_sync(sync)

    @item.reload
    assert @item.good?
    assert @item.pending_account_setup?
  end

  test "processes and schedules linked accounts" do
    revolut_x_account = @item.revolut_x_accounts.create!(name: "Revolut X", account_id: "default", account_type: "exchange", currency: "USD")
    AccountProvider.create!(account: accounts(:crypto), provider: revolut_x_account)
    sync = @item.syncs.create!
    @item.expects(:import_latest_revolut_x_data).returns(success: true)
    @item.expects(:process_accounts).returns([])
    @item.expects(:schedule_account_syncs).returns([])

    RevolutXItem::Syncer.new(@item).perform_sync(sync)

    assert_not @item.reload.pending_account_setup?
  end
end
