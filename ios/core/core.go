package core

import (
	"bytes"
	"crypto/ed25519"
	"crypto/rand"
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

type signatureBlob struct {
	Version       uint32
	PublicKey     []byte
	Namespace     string
	Reserved      string
	HashAlgorithm string
	Signature     []byte
}

type signedData struct {
	Namespace, Reserved, HashAlgorithm string
	Hash                               []byte
}

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
	var signature signatureBlob
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
	signed := append(slices.Clone(signatureMagic),
		ssh.Marshal(signedData{namespace, signature.Reserved, signature.HashAlgorithm, hash})...)

	var wireSignature ssh.Signature
	if err := ssh.Unmarshal(signature.Signature, &wireSignature); err != nil {
		return "", err
	}
	if err := publicKey.Verify(signed, &wireSignature); err != nil {
		return "", err
	}
	return signer, nil
}

func Sign(privateKey []byte, content []byte) ([]byte, error) {
	if len(privateKey) != ed25519.SeedSize {
		return nil, errors.New("private key must be 32 bytes")
	}
	signer, err := ssh.NewSignerFromKey(ed25519.NewKeyFromSeed(privateKey))
	if err != nil {
		return nil, err
	}

	hash := sha512.Sum512(content)
	signed := append(slices.Clone(signatureMagic), ssh.Marshal(signedData{namespace, "", "sha512", hash[:]})...)
	wireSignature, err := signer.Sign(rand.Reader, signed)
	if err != nil {
		return nil, err
	}

	blob := append(slices.Clone(signatureMagic), ssh.Marshal(signatureBlob{
		Version:       1,
		PublicKey:     signer.PublicKey().Marshal(),
		Namespace:     namespace,
		HashAlgorithm: "sha512",
		Signature:     ssh.Marshal(wireSignature),
	})...)
	return pem.EncodeToMemory(&pem.Block{Type: "SSH SIGNATURE", Bytes: blob}), nil
}

func Encrypt(recipientPublicKeys string, plaintext []byte) ([]byte, error) {
	var recipients []age.Recipient
	for _, publicKey := range strings.Fields(recipientPublicKeys) {
		recipient, err := agessh.ParseRecipient("ssh-ed25519 " + publicKey)
		if err != nil {
			return nil, err
		}
		recipients = append(recipients, recipient)
	}

	var ciphertext bytes.Buffer
	writer, err := age.Encrypt(&ciphertext, recipients...)
	if err != nil {
		return nil, err
	}
	if _, err := writer.Write(plaintext); err != nil {
		return nil, err
	}
	if err := writer.Close(); err != nil {
		return nil, err
	}
	return ciphertext.Bytes(), nil
}
