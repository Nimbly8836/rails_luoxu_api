# frozen_string_literal: true

class Username < ApplicationRecord
  validates :uid, :group_id, :name, :last_seen, presence: true
  validates :uid, numericality: { only_integer: true }
  validates :group_id, numericality: { only_integer: true }
end
