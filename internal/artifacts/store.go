package artifacts

import (
	"crypto/rand"
	"encoding/hex"
	"errors"
	"fmt"
	"io"
	"os"
	"path/filepath"
	"strings"
	"time"
)

const DefaultLimit int64 = 64 << 20

type Store struct {
	Root  string
	Limit int64
}

func New(root string, limit int64) (*Store, error) {
	if root == "" {
		cache, err := os.UserCacheDir()
		if err != nil {
			return nil, err
		}
		root = filepath.Join(cache, "jb-p1lot", "artifacts")
	}
	if limit <= 0 {
		limit = DefaultLimit
	}
	if err := os.MkdirAll(root, 0o700); err != nil {
		return nil, err
	}
	return &Store{Root: root, Limit: limit}, nil
}

func (s *Store) Write(name string, reader io.Reader, size int64) (string, error) {
	if s == nil {
		return "", errors.New("artifact store is nil")
	}
	if size < 0 || size > s.Limit {
		return "", fmt.Errorf("artifact size %d exceeds limit %d", size, s.Limit)
	}
	name = filepath.Base(name)
	if name == "." || name == string(filepath.Separator) || strings.TrimSpace(name) == "" {
		name = "artifact"
	}
	var random [8]byte
	if _, err := rand.Read(random[:]); err != nil {
		return "", err
	}
	fileName := fmt.Sprintf("%d-%s-%s", time.Now().UnixNano(), hex.EncodeToString(random[:]), name)
	path := filepath.Join(s.Root, fileName)
	tmp, err := os.CreateTemp(s.Root, ".artifact-")
	if err != nil {
		return "", err
	}
	tmpName := tmp.Name()
	defer os.Remove(tmpName)
	if _, err := io.CopyN(tmp, reader, size); err != nil && !(errors.Is(err, io.EOF) && size == 0) {
		tmp.Close()
		return "", err
	}
	if err := tmp.Sync(); err != nil {
		tmp.Close()
		return "", err
	}
	if err := tmp.Close(); err != nil {
		return "", err
	}
	if err := os.Chmod(tmpName, 0o600); err != nil {
		return "", err
	}
	if err := os.Rename(tmpName, path); err != nil {
		return "", err
	}
	return path, nil
}

func (s *Store) WriteBytes(name string, data []byte) (string, error) {
	return s.Write(name, strings.NewReader(string(data)), int64(len(data)))
}

func (s *Store) Read(path string, limit int64) ([]byte, error) {
	if limit <= 0 || limit > s.Limit {
		limit = s.Limit
	}
	clean := filepath.Clean(path)
	root := filepath.Clean(s.Root) + string(filepath.Separator)
	if !strings.HasPrefix(clean, root) {
		return nil, errors.New("artifact path is outside store")
	}
	file, err := os.Open(clean)
	if err != nil {
		return nil, err
	}
	defer file.Close()
	return io.ReadAll(io.LimitReader(file, limit+1))
}
