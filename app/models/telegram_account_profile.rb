# frozen_string_literal: true

class TelegramAccountProfile < ApplicationRecord
  belongs_to :telegram_account
  has_many :watch_targets,
           class_name: "TelegramAccountWatchTarget",
           primary_key: :telegram_account_id,
           foreign_key: :telegram_account_id

  validates :telegram_account_id, uniqueness: true

  def self.all_watched_chat_ids
    TelegramAccountWatchTarget.distinct.order(:td_chat_id).pluck(:td_chat_id)
  end

  def watched_chat_ids
    watch_targets.order(:td_chat_id).pluck(:td_chat_id)
  end

  def watched_chat_ids=(chat_ids)
    replace_watched_chat_ids!(chat_ids)
  end

  def replace_watched_chat_ids!(chat_ids)
    raise ArgumentError, "telegram_account_id is required" if telegram_account_id.blank?

    ids = normalize_chat_ids(chat_ids)
    TelegramAccountWatchTarget.transaction do
      TelegramAccountWatchTarget.where(telegram_account_id: telegram_account_id).where.not(td_chat_id: ids).delete_all
      upsert_watch_targets!(telegram_account_id, ids)
    end
    ids
  end

  def self.append_watched_chat_ids_for_chat_ids!(chat_ids)
    ids = normalize_chat_ids(chat_ids)
    return {} if ids.empty?

    rows = TelegramChat.where(td_chat_id: ids).distinct.pluck(:telegram_account_id, :td_chat_id)
    return {} if rows.empty?

    pairs = rows.map { |account_id, td_chat_id| [ account_id.to_i, td_chat_id.to_i ] }
    account_ids = pairs.map(&:first).uniq
    td_chat_ids = pairs.map(&:last).uniq
    existing_pairs = TelegramAccountWatchTarget.where(
      telegram_account_id: account_ids,
      td_chat_id: td_chat_ids
    ).pluck(:telegram_account_id, :td_chat_id).map { |account_id, td_chat_id| [ account_id.to_i, td_chat_id.to_i ] }
    existing_set = existing_pairs.each_with_object({}) { |pair, memo| memo[pair] = true }

    added_by_account = Hash.new { |hash, key| hash[key] = [] }
    payload = pairs.each_with_object([]) do |(account_id, td_chat_id), memo|
      next if existing_set[[ account_id, td_chat_id ]]

      added_by_account[account_id] << td_chat_id
      memo << {
        telegram_account_id: account_id,
        td_chat_id: td_chat_id,
        created_at: Time.current,
        updated_at: Time.current
      }
    end

    return {} if payload.empty?

    TelegramAccount.where(id: added_by_account.keys).find_each do |account|
      find_or_create_by!(telegram_account_id: account.id)
    end

    TelegramAccountWatchTarget.insert_all(
      payload,
      unique_by: :index_telegram_account_watch_targets_on_account_and_chat
    )

    added_by_account.transform_values { |values| values.uniq.sort }
  end

  def self.normalize_chat_ids(chat_ids)
    Array(chat_ids).map(&:to_i).reject(&:zero?).uniq.sort
  end

  private

  def normalize_chat_ids(chat_ids)
    self.class.normalize_chat_ids(chat_ids)
  end

  def upsert_watch_targets!(account_id, chat_ids)
    return if chat_ids.empty?

    payload = chat_ids.map do |td_chat_id|
      {
        telegram_account_id: account_id,
        td_chat_id: td_chat_id,
        created_at: Time.current,
        updated_at: Time.current
      }
    end
    TelegramAccountWatchTarget.insert_all(
      payload,
      unique_by: :index_telegram_account_watch_targets_on_account_and_chat
    )
  end
end
