defmodule Peridiod.Cache.EncryptionTest do
  use ExUnit.Case, async: false

  alias Peridiod.Cache.Encryption

  @key :crypto.strong_rand_bytes(32)

  # ---------------------------------------------------------------------------
  # One-shot encrypt / decrypt
  # ---------------------------------------------------------------------------

  test "encrypt/decrypt roundtrip for small content" do
    plaintext = "hello, world"
    encrypted = Encryption.encrypt(plaintext, @key)
    assert is_binary(encrypted)
    assert encrypted != plaintext
    assert {:ok, ^plaintext} = Encryption.decrypt(encrypted, @key)
  end

  test "encrypt/decrypt roundtrip for empty content" do
    plaintext = ""
    encrypted = Encryption.encrypt(plaintext, @key)
    assert {:ok, ^plaintext} = Encryption.decrypt(encrypted, @key)
  end

  test "encrypt/decrypt roundtrip for exactly one chunk boundary" do
    plaintext = :crypto.strong_rand_bytes(65_536)
    encrypted = Encryption.encrypt(plaintext, @key)
    assert {:ok, ^plaintext} = Encryption.decrypt(encrypted, @key)
  end

  test "encrypt/decrypt roundtrip for multiple chunks" do
    plaintext = :crypto.strong_rand_bytes(200_000)
    encrypted = Encryption.encrypt(plaintext, @key)
    assert {:ok, ^plaintext} = Encryption.decrypt(encrypted, @key)
  end

  test "decrypt returns error for wrong key" do
    plaintext = "secret"
    encrypted = Encryption.encrypt(plaintext, @key)
    wrong_key = :crypto.strong_rand_bytes(32)
    assert {:error, :authentication_failed} = Encryption.decrypt(encrypted, wrong_key)
  end

  test "decrypt returns error for corrupted ciphertext" do
    plaintext = "secret data"
    encrypted = Encryption.encrypt(plaintext, @key)
    # Flip a bit in the ciphertext body (after the 13-byte header + 4-byte chunk len)
    <<header::binary-17, rest::binary>> = encrypted
    <<byte, tail::binary>> = rest
    corrupted = <<header::binary, Bitwise.bxor(byte, 0xFF), tail::binary>>
    assert {:error, :authentication_failed} = Encryption.decrypt(corrupted, @key)
  end

  test "decrypt returns error for invalid format" do
    assert {:error, :invalid_format} = Encryption.decrypt("not encrypted", @key)
    assert {:error, :invalid_format} = Encryption.decrypt(<<>>, @key)
  end

  test "each encrypt call produces different ciphertext" do
    plaintext = "same plaintext"
    ct1 = Encryption.encrypt(plaintext, @key)
    ct2 = Encryption.encrypt(plaintext, @key)
    # Different random nonces produce different ciphertext
    assert ct1 != ct2
    assert {:ok, ^plaintext} = Encryption.decrypt(ct1, @key)
    assert {:ok, ^plaintext} = Encryption.decrypt(ct2, @key)
  end

  # ---------------------------------------------------------------------------
  # File-level encrypt / decrypt
  # ---------------------------------------------------------------------------

  @tmp "test/workspace/cache/encryption_test"

  setup do
    File.mkdir_p!(@tmp)
    on_exit(fn -> File.rm_rf(@tmp) end)
    :ok
  end

  test "encrypt_file / decrypt_to_tempfile roundtrip" do
    plaintext = :crypto.strong_rand_bytes(100_000)
    plain_path = Path.join(@tmp, "plain")
    enc_path = Path.join(@tmp, "enc")

    File.write!(plain_path, plaintext)
    assert :ok = Encryption.encrypt_file(plain_path, enc_path, @key)

    temp_dir = Path.join(@tmp, "tmp")
    assert {:ok, temp_path} = Encryption.decrypt_to_tempfile(enc_path, temp_dir, @key)
    assert File.read!(temp_path) == plaintext
    File.rm(temp_path)
  end

  test "decrypt_to_tempfile fails for wrong key" do
    plaintext = "confidential"
    plain_path = Path.join(@tmp, "plain2")
    enc_path = Path.join(@tmp, "enc2")

    File.write!(plain_path, plaintext)
    :ok = Encryption.encrypt_file(plain_path, enc_path, @key)

    wrong_key = :crypto.strong_rand_bytes(32)
    temp_dir = Path.join(@tmp, "tmp2")

    assert {:error, :authentication_failed} =
             Encryption.decrypt_to_tempfile(enc_path, temp_dir, wrong_key)

    # Temp file should have been cleaned up
    assert Path.wildcard(Path.join(temp_dir, ".tmp_*")) == []
  end

  test "decrypt_to_tempfile fails for invalid format" do
    bad_path = Path.join(@tmp, "bad")
    File.write!(bad_path, "plaintext, not encrypted")

    temp_dir = Path.join(@tmp, "tmp3")
    assert {:error, :invalid_format} = Encryption.decrypt_to_tempfile(bad_path, temp_dir, @key)
  end

  # ---------------------------------------------------------------------------
  # Streaming decrypt
  # ---------------------------------------------------------------------------

  test "decrypt_stream yields decrypted chunks and valid eof" do
    plaintext = :crypto.strong_rand_bytes(150_000)
    plain_path = Path.join(@tmp, "stream_plain")
    enc_path = Path.join(@tmp, "stream_enc")

    File.write!(plain_path, plaintext)
    :ok = Encryption.encrypt_file(plain_path, enc_path, @key)

    # Build a real sig so decrypt_stream can verify it
    hash = Peridiod.Crypto.hash(enc_path, :sha256)
    {private_key, public_key} = test_keypair()
    sig_hex = Peridiod.Crypto.sign(hash, :sha256, private_key)
    {:ok, sig} = Base.decode16(sig_hex, case: :mixed)

    stream = Encryption.decrypt_stream(enc_path, :sha256, sig, public_key, @key)
    events = Enum.to_list(stream)

    {stream_events, [eof_event]} = Enum.split_while(events, &match?({:stream, _}, &1))
    assert {:eof, :valid_signature, _hash} = eof_event

    reassembled =
      stream_events |> Enum.map(fn {:stream, chunk} -> chunk end) |> IO.iodata_to_binary()

    assert reassembled == plaintext
  end

  test "decrypt_stream reports invalid_signature on wrong key" do
    plaintext = "secret"
    plain_path = Path.join(@tmp, "bad_key_plain")
    enc_path = Path.join(@tmp, "bad_key_enc")

    File.write!(plain_path, plaintext)
    :ok = Encryption.encrypt_file(plain_path, enc_path, @key)

    {private_key, public_key} = test_keypair()
    hash = Peridiod.Crypto.hash(enc_path, :sha256)
    sig_hex = Peridiod.Crypto.sign(hash, :sha256, private_key)
    {:ok, sig} = Base.decode16(sig_hex, case: :mixed)

    wrong_key = :crypto.strong_rand_bytes(32)
    stream = Encryption.decrypt_stream(enc_path, :sha256, sig, public_key, wrong_key)
    events = Enum.to_list(stream)

    assert Enum.any?(events, &match?({:eof, :invalid_signature, _}, &1))
  end

  # ---------------------------------------------------------------------------
  # Format detection
  # ---------------------------------------------------------------------------

  test "encrypted?/1 returns true for encrypted files" do
    plain_path = Path.join(@tmp, "detect_plain")
    enc_path = Path.join(@tmp, "detect_enc")
    File.write!(plain_path, "hello")
    :ok = Encryption.encrypt_file(plain_path, enc_path, @key)
    assert Encryption.encrypted?(enc_path)
  end

  test "encrypted?/1 returns false for plaintext files" do
    plain_path = Path.join(@tmp, "detect_plain2")
    File.write!(plain_path, "hello")
    refute Encryption.encrypted?(plain_path)
  end

  test "encrypted?/1 returns false for missing files" do
    refute Encryption.encrypted?(Path.join(@tmp, "nonexistent"))
  end

  # ---------------------------------------------------------------------------
  # DEK lifecycle
  # ---------------------------------------------------------------------------

  test "load_or_create_dek generates a DEK on first call" do
    dek_dir = Path.join(@tmp, "dek_test")
    {private_key, public_key} = test_keypair()

    assert {:ok, dek} = Encryption.load_or_create_dek(dek_dir, private_key, public_key)
    assert byte_size(dek) == 32
    assert File.exists?(Path.join(dek_dir, ".dek"))
    assert File.exists?(Path.join(dek_dir, ".dek.sig"))
  end

  test "load_or_create_dek returns same DEK on subsequent calls" do
    dek_dir = Path.join(@tmp, "dek_test2")
    {private_key, public_key} = test_keypair()

    {:ok, dek1} = Encryption.load_or_create_dek(dek_dir, private_key, public_key)
    {:ok, dek2} = Encryption.load_or_create_dek(dek_dir, private_key, public_key)
    assert dek1 == dek2
  end

  test "load_or_create_dek fails when DEK signature is invalid" do
    dek_dir = Path.join(@tmp, "dek_tamper")
    {private_key, public_key} = test_keypair()

    {:ok, _dek} = Encryption.load_or_create_dek(dek_dir, private_key, public_key)
    # Overwrite DEK file with different bytes (signature becomes invalid)
    File.write!(Path.join(dek_dir, ".dek"), :crypto.strong_rand_bytes(32))

    assert {:error, :dek_signature_invalid} =
             Encryption.load_or_create_dek(dek_dir, private_key, public_key)
  end

  # ---------------------------------------------------------------------------
  # Helpers
  # ---------------------------------------------------------------------------

  defp test_keypair do
    private_key_pem = File.read!("test/fixtures/device/device-private-key.pem")
    private_key = X509.PrivateKey.from_pem!(private_key_pem)
    cert_pem = File.read!("test/fixtures/device/device-certificate.pem")
    public_key = X509.Certificate.from_pem!(cert_pem) |> X509.Certificate.public_key()
    {private_key, public_key}
  end
end
