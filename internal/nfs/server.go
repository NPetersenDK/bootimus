package nfs

import (
	"context"
	"fmt"
	"log"
	"net"
	"strings"

	billy "github.com/go-git/go-billy/v5"
	"github.com/go-git/go-billy/v5/osfs"
	gonfs "github.com/willscott/go-nfs"
	nfshelper "github.com/willscott/go-nfs/helpers"
)

type Server struct {
	rootDir  string
	port     int
	listener net.Listener
}

func NewServer(rootDir string, port int) *Server {
	return &Server{
		rootDir: rootDir,
		port:    port,
	}
}

func (s *Server) Start() error {
	addr := fmt.Sprintf(":%d", s.port)
	listener, err := net.Listen("tcp", addr)
	if err != nil {
		return fmt.Errorf("failed to start NFS server: %w", err)
	}

	s.listener = listener
	log.Printf("NFS server listening on %s (export root %s)", addr, s.rootDir)

	root := osfs.New(s.rootDir)
	handler := &bootHandler{
		Handler: nfshelper.NewNullAuthHandler(root),
		root:    root,
	}
	cache := nfshelper.NewCachingHandler(handler, 1024)

	return gonfs.Serve(listener, cache)
}

func (s *Server) Stop() error {
	if s.listener != nil {
		return s.listener.Close()
	}
	return nil
}

type bootHandler struct {
	gonfs.Handler
	root billy.Filesystem
}

func (h *bootHandler) Mount(ctx context.Context, conn net.Conn, req gonfs.MountRequest) (gonfs.MountStatus, billy.Filesystem, []gonfs.AuthFlavor) {
	sub := strings.Trim(strings.ReplaceAll(string(req.Dirpath), "\\", "/"), "/")
	if sub == "" {
		return gonfs.MountStatusOk, h.root, []gonfs.AuthFlavor{gonfs.AuthFlavorNull}
	}

	fs, err := h.root.Chroot(sub)
	if err != nil {
		log.Printf("NFS: mount rejected for %q: %v", sub, err)
		return gonfs.MountStatusErrNoEnt, nil, nil
	}

	return gonfs.MountStatusOk, fs, []gonfs.AuthFlavor{gonfs.AuthFlavorNull}
}

func (h *bootHandler) Change(billy.Filesystem) billy.Change {
	return nil
}
