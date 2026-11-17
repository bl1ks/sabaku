# frozen_string_literal: true

ActiveRecord::Schema[8.1].define(version: 2026_01_01_000000) do
  create_table "accounts", force: :cascade do |t|
    t.string "name", null: false
  end

  create_table "tickets", force: :cascade do |t|
    t.integer "account_id", null: false
    t.string "status", null: false, default: "open"
    t.string "subject", null: false
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.index ["account_id"]
  end
end
