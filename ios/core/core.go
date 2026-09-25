package core

import (
	"crypto/ed25519"
	"encoding/base64"
	"errors"
	"strings"

	"golang.org/x/crypto/ssh"
)

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
