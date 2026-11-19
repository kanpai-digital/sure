# frozen_string_literal: true

class RevolutXAccount < ApplicationRecord
  include Encryptable

  if encryption_ready?
    encrypts :raw_payload
    encrypts :raw_transactions_payload
  end

  belongs_to :revolut_x_item

  has_one :account_provider, as: :provider, dependent: :destroy
  has_one :account, through: :account_provider, source: :account

  validates :name, :account_id, :account_type, :currency, presence: true

  def current_account
    account
  end
end
