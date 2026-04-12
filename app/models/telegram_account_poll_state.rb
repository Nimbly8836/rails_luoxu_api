# frozen_string_literal: true

class TelegramAccountPollState < ApplicationRecord
  belongs_to :telegram_account
end
