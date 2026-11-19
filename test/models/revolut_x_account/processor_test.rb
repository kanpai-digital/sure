# frozen_string_literal: true

require "test_helper"

class RevolutXAccount::ProcessorTest < ActiveSupport::TestCase
  setup do
    @family = families(:dylan_family)
    @family.update!(currency: "USD")
    @item = @family.revolut_x_items.create!(name: "Revolut X", api_key: "a1" * 32)
  end

  test "imports crypto as holdings and fiat as cash" do
    account = import_and_link

    RevolutXAccount::Processor.new(@revolut_x_account).process

    holdings = account.holdings.where(date: Date.current).includes(:security).index_by { |holding| holding.security.ticker }
    assert_equal %w[CRYPTO:BTC CRYPTO:ETH], holdings.keys.sort
    assert_equal 1.35.to_d, holdings["CRYPTO:BTC"].qty
    assert_equal 42, holdings["CRYPTO:ETH"].qty
    assert_equal 120_000, holdings["CRYPTO:BTC"].price
    assert_equal "revolut_x_BTC_#{Date.current}", holdings["CRYPTO:BTC"].external_id

    account.reload
    holdings_value = holdings.values.sum(&:amount)
    assert_equal 5500.50.to_d, account.cash_balance
    assert_equal holdings_value + 5500.50.to_d, account.balance
    assert_equal "USD", account.currency
  end

  test "skips an asset nothing prices and reports it" do
    account = import_and_link(extra_balances: [ { "currency" => "DOGE", "available" => "5", "reserved" => "0", "total" => "5" } ])

    assert_difference -> { DebugLogEntry.where(provider_key: "revolut_x").count }, 1 do
      RevolutXAccount::Processor.new(@revolut_x_account).process
    end

    assert_not account.holdings.joins(:security).exists?(securities: { ticker: "CRYPTO:DOGE" })
    assert_match "DOGE", DebugLogEntry.where(provider_key: "revolut_x").last.message
  end

  private

    def import_and_link(extra_balances: [])
      provider = mock
      provider.stubs(:get_balances).returns(payload("balances") + extra_balances)
      provider.stubs(:get_sub_accounts).returns(payload("sub_accounts"))
      provider.stubs(:get_currencies).returns(payload("currencies"))
      tickers = payload("tickers")
      tickers["data"] << { "symbol" => "ETH/USD", "mid" => "3000.00" }
      provider.stubs(:get_tickers).returns(tickers)
      RevolutXItem::Importer.new(@item, revolut_x_provider: provider).import

      @revolut_x_account = @item.revolut_x_accounts.sole
      account = Account.create_from_revolut_x_account(@revolut_x_account)
      AccountProvider.create!(account: account, provider: @revolut_x_account)
      @revolut_x_account.reload
      account
    end

    def payload(name)
      JSON.parse(file_fixture("revolut_x/#{name}.json").read)
    end
end
