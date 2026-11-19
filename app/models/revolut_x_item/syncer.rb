# frozen_string_literal: true

class RevolutXItem::Syncer
  include SyncStats::Collector

  attr_reader :revolut_x_item

  def initialize(revolut_x_item)
    @revolut_x_item = revolut_x_item
  end

  def perform_sync(sync)
    sync.update!(status_text: I18n.t("revolut_x_item.syncer.checking_credentials")) if sync.respond_to?(:status_text)
    unless revolut_x_item.credentials_configured?
      revolut_x_item.update!(status: :requires_update)
      mark_failed(sync, I18n.t("revolut_x_item.syncer.credentials_invalid"))
      return
    end

    sync.update!(status_text: I18n.t("revolut_x_item.syncer.importing_accounts")) if sync.respond_to?(:status_text)
    revolut_x_item.import_latest_revolut_x_data
    revolut_x_item.update!(status: :good) if revolut_x_item.requires_update?

    sync.update!(status_text: I18n.t("revolut_x_item.syncer.checking_configuration")) if sync.respond_to?(:status_text)
    collect_setup_stats(sync, provider_accounts: revolut_x_item.revolut_x_accounts.to_a)

    unlinked = revolut_x_item.revolut_x_accounts.left_joins(:account_provider).where(account_providers: { id: nil })
    linked = revolut_x_item.revolut_x_accounts.joins(:account_provider).joins(:account).merge(Account.visible)

    if unlinked.any?
      revolut_x_item.update!(pending_account_setup: true)
      sync.update!(status_text: I18n.t("revolut_x_item.syncer.accounts_need_setup", count: unlinked.count)) if sync.respond_to?(:status_text)
    else
      revolut_x_item.update!(pending_account_setup: false)
    end

    return unless linked.any?

    sync.update!(status_text: I18n.t("revolut_x_item.syncer.processing_accounts")) if sync.respond_to?(:status_text)
    revolut_x_item.process_accounts

    sync.update!(status_text: I18n.t("revolut_x_item.syncer.calculating_balances")) if sync.respond_to?(:status_text)
    revolut_x_item.schedule_account_syncs(
      parent_sync: sync,
      window_start_date: sync.window_start_date,
      window_end_date: sync.window_end_date
    )
  rescue Provider::RevolutX::AuthenticationError => e
    revolut_x_item.update!(status: :requires_update)
    mark_failed(sync, e.message)
    raise
  rescue StandardError => e
    Rails.logger.error "RevolutXItem::Syncer - unexpected error during sync: #{e.message}\n#{e.backtrace&.first(5)&.join("\n")}"
    mark_failed(sync, e.message)
    raise
  end

  def perform_post_sync
  end

  private

    def mark_failed(sync, error_message)
      sync.start! if sync.respond_to?(:may_start?) && sync.may_start?

      if sync.respond_to?(:may_fail?) && sync.may_fail?
        sync.fail!
      elsif sync.respond_to?(:status)
        sync.update!(status: :failed)
      end

      sync.update!(error: error_message) if sync.respond_to?(:error)
      sync.update!(status_text: error_message) if sync.respond_to?(:status_text)
    end
end
