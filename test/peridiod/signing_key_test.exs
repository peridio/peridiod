defmodule Peridiod.SigningKeyTest do
  use PeridiodTest.Case
  doctest Peridiod.SigningKey

  alias Peridiod.SigningKey

  @trusted_key_pem """
  -----BEGIN PUBLIC KEY-----
  MCowBQYDK2VwAyEAR/D9tfoPRSJi+pd+S6MQqjPfjfyXm9OO65n+RyJ1gbk=
  -----END PUBLIC KEY-----
  """
  @trusted_key_der <<71, 240, 253, 181, 250, 15, 69, 34, 98, 250, 151, 126, 75, 163, 16, 170, 51,
                     223, 141, 252, 151, 155, 211, 142, 235, 153, 254, 71, 34, 117, 129, 185>>
  @trusted_key_base64 "R/D9tfoPRSJi+pd+S6MQqjPfjfyXm9OO65n+RyJ1gbk="

  describe "convert keys" do
    test "pem to der" do
      assert SigningKey.ed25519_public_pem_to_der(@trusted_key_pem) == {:ok, @trusted_key_der}
    end

    test "raw to der" do
      assert SigningKey.ed25519_public_raw_to_der(@trusted_key_base64) == {:ok, @trusted_key_der}
    end
  end
end
