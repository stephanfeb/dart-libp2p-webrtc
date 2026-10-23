// Circuit relay v2 server on go-libp2p, for the interop tests: TCP for Dart
// hosts, WebSockets for browsers. It keeps go-libp2p's default relay limits
// (2 min, 128 KiB per relayed connection), which go-ricochet also uses, so
// relayed connections through it are limited. Prints one JSON line with its
// peer id and addresses, then runs until stdin closes.
//
// Flags: -ip (default 127.0.0.1; 0.0.0.0 for phones on the LAN), -tcp and
// -ws ports (default 0, any).
package main

import (
	"encoding/json"
	"flag"
	"fmt"
	"io"
	"os"

	"github.com/libp2p/go-libp2p"
	"github.com/libp2p/go-libp2p/p2p/protocol/circuitv2/relay"
	"github.com/libp2p/go-libp2p/p2p/transport/tcp"
	"github.com/libp2p/go-libp2p/p2p/transport/websocket"
)

func main() {
	ip := flag.String("ip", "127.0.0.1", "IPv4 address to listen on")
	tcpPort := flag.Int("tcp", 0, "TCP port")
	wsPort := flag.Int("ws", 0, "WebSocket port")
	flag.Parse()

	resources := relay.DefaultResources()
	// Loopback tests make every reservation from one IP.
	resources.MaxReservationsPerIP = 64
	host, err := libp2p.New(
		libp2p.ListenAddrStrings(
			fmt.Sprintf("/ip4/%s/tcp/%d", *ip, *tcpPort),
			fmt.Sprintf("/ip4/%s/tcp/%d/ws", *ip, *wsPort),
		),
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
