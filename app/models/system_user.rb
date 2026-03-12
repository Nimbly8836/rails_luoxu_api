# frozen_string_literal: true

class SystemUser < ApplicationRecord
  has_secure_password

  has_many :chat_accesses, class_name: "SystemUserChatAccess", dependent: :destroy

  validates :username, presence: true, uniqueness: true
  validates :api_token, presence: true, uniqueness: true
  validates :admin, inclusion: { in: [ true, false ] }

  before_validation :ensure_api_token, on: :create

  private

  def ensure_api_token
    self.api_token ||= SecureRandom.hex(32)
  end
end
