// Circuit relay v2 server on go-libp2p, for the interop tests: TCP for Dart
// hosts, WebSockets for browsers. It keeps go-libp2p's default relay limits
// (2 min, 128 KiB per relayed connection), which go-ricochet also uses, so
// relayed connections through it are limited. Prints one JSON line with its
// peer id and addresses, then runs until stdin closes.
package main

import (
	"encoding/json"
	"fmt"
	"io"
	"os"

	"github.com/libp2p/go-libp2p"
	"github.com/libp2p/go-libp2p/p2p/protocol/circuitv2/relay"
	"github.com/libp2p/go-libp2p/p2p/transport/tcp"
	"github.com/libp2p/go-libp2p/p2p/transport/websocket"
)

func main() {
	resources := relay.DefaultResources()
	// Loopback tests make every reservation from one IP.
	resources.MaxReservationsPerIP = 64
	host, err := libp2p.New(
		libp2p.ListenAddrStrings("/ip4/127.0.0.1/tcp/0", "/ip4/127.0.0.1/tcp/0/ws"),
		libp2p.Transport(tcp.NewTCPTransport),
		libp2p.Transport(websocket.New),
		libp2p.ForceReachabilityPublic(),
		libp2p.EnableRelayService(relay.WithResources(resources)),
	)
	if err != nil {
		fmt.Fprintln(os.Stderr, err)
		os.Exit(1)
	}
	defer host.Close()

	addrs := []string{}
	for _, a := range host.Addrs() {
		addrs = append(addrs, fmt.Sprintf("%s/p2p/%s", a, host.ID()))
	}
	limit := resources.Limit
	json.NewEncoder(os.Stdout).Encode(map[string]any{
		"peerId":    host.ID().String(),
		"addrs":     addrs,
		"limitSecs": limit.Duration.Seconds(),
		"limitData": limit.Data,
	})

	io.Copy(io.Discard, os.Stdin)
}
