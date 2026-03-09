# frozen_string_literal: true

class SystemUserChatAccess < ApplicationRecord
  belongs_to :system_user

  validates :td_chat_id, presence: true, uniqueness: { scope: :system_user_id }
end
