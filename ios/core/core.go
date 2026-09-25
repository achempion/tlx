package core

import (
	"bytes"
	"crypto/ed25519"
	"crypto/sha256"
	"crypto/sha512"
	"encoding/base64"
	"encoding/pem"
	"errors"
	"io"
	"slices"
	"strings"

	"filippo.io/age"
	"filippo.io/age/agessh"
	"golang.org/x/crypto/ssh"
)

const namespace = "chat"

var signatureMagic = []byte("SSHSIG")

type KeyPair struct {
	PrivateKey []byte
	PublicKey  string
}

func ParseKey(privateKeyPEM string) (*KeyPair, error) {
	anyPrivateKey, err := ssh.ParseRawPrivateKey([]byte(strings.TrimSpace(privateKeyPEM)))
	var passphraseMissing *ssh.PassphraseMissingError
	if errors.As(err, &passphraseMissing) {
		return nil, errors.New("keys with a passphrase are not supported")
	}
	if err != nil {
		return nil, errors.New("not an OpenSSH private key")
	}

	var ed25519PrivateKey ed25519.PrivateKey
	switch privateKey := anyPrivateKey.(type) {
	case *ed25519.PrivateKey:
		ed25519PrivateKey = *privateKey
	case ed25519.PrivateKey:
		ed25519PrivateKey = privateKey
	default:
		return nil, errors.New("not an Ed25519 key")
	}

	sshPublicKey, err := ssh.NewPublicKey(ed25519PrivateKey.Public())
	if err != nil {
		return nil, err
	}

	return &KeyPair{
		PrivateKey: ed25519PrivateKey.Seed(),
		PublicKey:  base64.StdEncoding.EncodeToString(sshPublicKey.Marshal()),
	}, nil
}

func Decrypt(privateKey []byte, ciphertext []byte) ([]byte, error) {
	if len(privateKey) != ed25519.SeedSize {
		return nil, errors.New("private key must be 32 bytes")
	}
	identity, err := agessh.NewEd25519Identity(ed25519.NewKeyFromSeed(privateKey))
	if err != nil {
		return nil, err
	}

	plaintext, err := age.Decrypt(bytes.NewReader(ciphertext), identity)
	if err != nil {
		return nil, err
	}
	return io.ReadAll(plaintext)
}

func Verify(signedContent []byte, armoredSignature []byte, allowedSigners string) (string, error) {
	block, _ := pem.Decode(armoredSignature)
	if block == nil || block.Type != "SSH SIGNATURE" || !bytes.HasPrefix(block.Bytes, signatureMagic) {
		return "", errors.New("not an SSH signature")
	}
	var signature struct {
		Version       uint32
		PublicKey     []byte
		Namespace     string
		Reserved      string
		HashAlgorithm string
		Signature     []byte
	}
	if err := ssh.Unmarshal(block.Bytes[len(signatureMagic):], &signature); err != nil {
		return "", err
	}
	if signature.Version != 1 || signature.Namespace != namespace {
		return "", errors.New("unexpected signature version or namespace")
	}

	publicKey, err := ssh.ParsePublicKey(signature.PublicKey)
	if err != nil {
		return "", err
	}
	signer := base64.StdEncoding.EncodeToString(publicKey.Marshal())
	if !slices.Contains(strings.Fields(allowedSigners), signer) {
		return "", errors.New("signer is not a recipient")
	}

	var hash []byte
	switch signature.HashAlgorithm {
	case "sha256":
		sum := sha256.Sum256(signedContent)
		hash = sum[:]
	case "sha512":
		sum := sha512.Sum512(signedContent)
		hash = sum[:]
	default:
		return "", errors.New("unsupported hash algorithm")
	}
	signedData := append(slices.Clone(signatureMagic), ssh.Marshal(struct {
		Namespace, Reserved, HashAlgorithm string
		Hash                               []byte
	}{namespace, signature.Reserved, signature.HashAlgorithm, hash})...)

	var wireSignature ssh.Signature
	if err := ssh.Unmarshal(signature.Signature, &wireSignature); err != nil {
		return "", err
	}
	if err := publicKey.Verify(signedData, &wireSignature); err != nil {
		return "", err
	}
	return signer, nil
}
