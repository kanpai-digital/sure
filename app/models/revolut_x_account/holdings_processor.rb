# frozen_string_literal: true

class RevolutXAccount::HoldingsProcessor
  def initialize(revolut_x_account)
    @revolut_x_account = revolut_x_account
  end

  def process
    return unless account&.accountable_type == "Crypto"

    crypto_assets.each { |asset| process_asset(asset) }
    zero_absent_holdings
  end

  private

    attr_reader :revolut_x_account

    def account
      revolut_x_account.current_account
    end

    def currency
      revolut_x_account.revolut_x_item.family.currency
    end

    def crypto_assets
      revolut_x_account.raw_payload.to_h.fetch("assets", []).select { |asset| asset["kind"] == "crypto" }
    end

    # Staked and reserved units are still owned, so the holding is the total.
    def process_asset(asset)
      symbol = asset["symbol"]
      quantity = asset["total"].to_d
      return if quantity.zero?

      security = Onchain::SecurityResolver.resolve(symbol: symbol, name: asset["name"]) if asset["price_usd"].present?
      return revolut_x_account.report_unvalued_asset(symbol, source: self.class.name) unless security

      price = Money.new(asset["price_usd"].to_d, "USD").exchange_to(currency).amount

      import_adapter.import_holding(
        security: security,
        quantity: quantity,
        amount: quantity * price,
        currency: currency,
        date: Date.current,
        price: price,
        cost_basis: nil,
        external_id: "revolut_x_#{symbol}_#{Date.current}",
        account_provider_id: revolut_x_account.account_provider&.id,
        source: "revolut_x",
        delete_future_holdings: false
      )
    end

    # A coin that left the account has no row in the payload, so without a
    # today-dated zero its last provider snapshot would keep counting as held.
    # Coins still in the payload are not zeroed, priced or not: they are owned.
    def zero_absent_holdings
      # No assets array means no snapshot, not an empty account.
      return unless revolut_x_account.raw_payload.to_h["assets"].is_a?(Array)

      provider_link = revolut_x_account.account_provider
      return unless provider_link

      present_tickers = crypto_assets.filter_map do |asset|
        ticker_symbol = Onchain::SecurityResolver.new(symbol: asset["symbol"]).ticker_symbol
        "#{Onchain::SecurityResolver::TICKER_PREFIX}#{ticker_symbol}" if ticker_symbol
      end
      held_security_ids = account.holdings.where(account_provider_id: provider_link.id)
        .distinct.pluck(Arel.sql("COALESCE(provider_security_id, security_id)"))

      Security.where(id: held_security_ids).where.not(ticker: present_tickers).find_each do |security|
        import_adapter.import_holding(
          security: security,
          quantity: 0,
          amount: 0,
          currency: currency,
          date: Date.current,
          price: 0,
          cost_basis: nil,
          external_id: "revolut_x_#{security.ticker.delete_prefix(Onchain::SecurityResolver::TICKER_PREFIX)}_#{Date.current}",
          account_provider_id: provider_link.id,
          source: "revolut_x",
          delete_future_holdings: false
        )
      end
    end

    def import_adapter
      @import_adapter ||= Account::ProviderImportAdapter.new(account)
    end
end
