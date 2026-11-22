# frozen_string_literal: true

# A class body that runs its block at load time, the shape of dry-validation's `params do`.
class Contract
  def self.params
    @params = yield
  end

  def self.limit
    @params.fetch(:limit)
  end

  params do
    { limit: 10 }
  end
end
