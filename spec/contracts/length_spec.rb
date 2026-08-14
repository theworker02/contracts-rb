# frozen_string_literal: true
require "spec_helper"

RSpec.describe "all and length constraints" do
  describe Contracts::Constraints::All do
    subject(:constraint) { Contracts.all(String, Contracts.matching(/\A[A-Z]/)) }

    it "requires every nested constraint to match" do
      expect(constraint.matches?("OK")).to be(true)
      expect(constraint.matches?("ok")).to be(false)
      expect(constraint.matches?(1)).to be(false)
    end

    it "describes the conjunction" do
      expect(constraint.description).to include(" and ")
    end
  end

  describe Contracts::Constraints::Length do
    it "enforces min and max length" do
      constraint = Contracts.length(min: 2, max: 4)
      expect(constraint.matches?("ab")).to be(true)
      expect(constraint.matches?([1, 2, 3, 4])).to be(true)
      expect(constraint.matches?("a")).to be(false)
      expect(constraint.matches?("abcde")).to be(false)
      expect(constraint.matches?(12)).to be(false)
    end

    it "enforces exact length" do
      constraint = Contracts.length(exactly: 3)
      expect(constraint.matches?("hey")).to be(true)
      expect(constraint.matches?({ a: 1, b: 2, c: 3 })).to be(true)
      expect(constraint.matches?("hi")).to be(false)
    end

    it "rejects inverted bounds" do
      expect { Contracts.length(min: 5, max: 1) }.to raise_error(Contracts::DefinitionError)
    end
  end
end
