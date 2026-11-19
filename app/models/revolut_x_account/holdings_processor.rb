# frozen_string_literal: true

class RevolutXAccount::HoldingsProcessor
  def initialize(revolut_x_account)
    @revolut_x_account = revolut_x_account
  end

  def process
    return unless account&.accountable_type == "Crypto"

    crypto_assets.each { |asset| process_asset(asset) }
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
      return report_skipped(symbol) unless security

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

    def report_skipped(symbol)
      DebugLogEntry.capture(
        category: "provider_sync_error",
        level: "warn",
        message: "Revolut X holding #{symbol} skipped: no price or usable ticker",
        source: self.class.name,
        provider_key: "revolut_x",
        family: revolut_x_account.revolut_x_item.family,
        account_provider: revolut_x_account.account_provider,
        metadata: { revolut_x_item_id: revolut_x_account.revolut_x_item_id, symbol: symbol }
      )
    end

    def import_adapter
      @import_adapter ||= Account::ProviderImportAdapter.new(account)
    end
end
