defmodule Peridiod.CryptoTest do
  use PeridiodTest.Case

  alias Peridiod.Crypto

  describe "RSA" do
    test "can sign and verify with RSA keys" do
      # Generate a real RSA key pair
      priv = :public_key.generate_key({:rsa, 2048, 65537})
      {:RSAPrivateKey, _, n, e, _, _, _, _, _, _, _} = priv
      pub = {:RSAPublicKey, n, e}

      # Test signing and verification
      msg = "test message"
      signature_hex = Crypto.sign(msg, :sha256, priv)

      # Decode signature for verification
      {:ok, signature} = Base.decode16(signature_hex, case: :mixed)

      assert Crypto.verified?(msg, :sha256, signature, pub)
    end

    test "can handle engine key references" do
      engine_key = %{engine: make_ref(), key_id: "pkcs11:dummy", algorithm: :rsa}

      assert_raise ErlangError, ~r/Couldn't get engine and\/or key id/, fn ->
        Crypto.sign("abc", :sha256, engine_key)
      end
    end
  end

  describe "ECDSA" do
    test "can sign and verify with ECDSA keys" do
      # Generate an ECDSA key pair using public_key module
      ecdsa_private = :public_key.generate_key({:namedCurve, :secp256r1})

      # Extract public key from private key
      {:ECPrivateKey, _version, _private_key, {:namedCurve, curve_oid}, public_key_point,
       _attributes} = ecdsa_private

      ecdsa_public = {{:ECPoint, public_key_point}, {:namedCurve, curve_oid}}

      # Test signing and verification
      hash = "test message hash"
      signature_hex = Crypto.sign(hash, :sha256, ecdsa_private)

      # Decode signature for verification
      {:ok, signature} = Base.decode16(signature_hex, case: :mixed)

      assert Crypto.verified?(hash, :sha256, signature, ecdsa_public)
    end

    test "can handle engine key references" do
      engine_key = %{engine: make_ref(), key_id: "pkcs11:dummy", algorithm: :ecdsa}

      assert_raise ErlangError, ~r/Couldn't get engine and\/or key id/, fn ->
        Crypto.sign("abc", :sha256, engine_key)
      end
    end
  end

  describe "EDDSA" do
    test "can sign and verify with Ed25519 keys (standard ASN.1 format)" do
      # Generate an Ed25519 key pair using crypto module
      {public_key, private_key} = :crypto.generate_key(:eddsa, :ed25519)

      # Create proper key structures for Ed25519
      ed25519_private =
        {:ECPrivateKey, 1, private_key, {:namedCurve, {1, 3, 101, 112}}, public_key,
         :asn1_NOVALUE}

      ed25519_public = {{:ECPoint, public_key}, {:namedCurve, {1, 3, 101, 112}}}

      # Test signing and verification
      hash = "test message hash"
      signature_hex = Crypto.sign(hash, :sha256, ed25519_private)

      # Decode signature for verification
      {:ok, signature} = Base.decode16(signature_hex, case: :mixed)

      assert Crypto.verified?(hash, :sha256, signature, ed25519_public)
    end

    test "can handle engine key references" do
      engine_key = %{engine: make_ref(), key_id: "pkcs11:dummy", algorithm: :eddsa}

      assert_raise ErlangError, ~r/Couldn't get engine and\/or key id/, fn ->
        Crypto.sign("abc", :sha256, engine_key)
      end
    end
  end

  describe "error handling" do
    test "raises error for unrecognized key format" do
      # Use a non-tuple format to avoid matching custom tuple patterns
      unsupported_key = %{some: "unknown", format: "here"}

      assert_raise ArgumentError, ~r/argument error/, fn ->
        Crypto.sign("test hash", :sha256, unsupported_key)
      end
    end

    test "raises error for engine key with invalid algorithm" do
      invalid_engine_key = %{engine: make_ref(), key_id: "pkcs11:dummy", algorithm: :invalid_algo}

      # This should not match the engine key guard and fall through to the catch-all
      assert_raise ArgumentError, ~r/Unrecognized key format/, fn ->
        Crypto.sign("test hash", :sha256, invalid_engine_key)
      end
    end
  end

  describe "hash functions" do
    test "can hash files" do
      # Create a temporary file
      temp_file = Path.join(System.tmp_dir!(), "crypto_test_#{:rand.uniform(1000)}")
      File.write!(temp_file, "test content")

      # Test hashing
      hash = Crypto.hash(temp_file, :sha256)

      # Verify it's a hex string
      assert is_binary(hash)
      # SHA256 is 32 bytes = 64 hex chars
      assert String.length(hash) == 64
      assert Regex.match?(~r/^[0-9a-f]+$/, hash)

      # Cleanup
      File.rm!(temp_file)
    end

    test "can do streaming hash operations" do
      # Test the streaming hash functions
      state = Crypto.hash_init(:sha256)
      state = Crypto.hash_update(state, "hello")
      state = Crypto.hash_update(state, " world")
      result = Crypto.hash_final(state)

      # Should be the same as hashing "hello world" directly
      expected = :crypto.hash(:sha256, "hello world")
      assert result == expected
    end
  end
end
