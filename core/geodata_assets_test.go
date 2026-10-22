package main

import (
	"os"
	"path/filepath"
	"testing"

	"github.com/metacubex/mihomo/component/geodata"
	_ "github.com/metacubex/mihomo/component/geodata/standard"
	"github.com/metacubex/mihomo/component/mmdb"
)

func TestBundledFourGeoAssetsAreReadable(t *testing.T) {
	root := filepath.Join("..", "assets", "data")
	loader, err := geodata.GetGeoDataLoader("standard")
	if err != nil {
		t.Fatal(err)
	}
	ip, err := os.ReadFile(filepath.Join(root, "GEOIP.dat"))
	if err != nil {
		t.Fatal(err)
	}
	ips, err := loader.LoadIPByBytes(ip, "cn")
	if err != nil || len(ips) == 0 {
		t.Fatalf("bundled GeoIP invalid: %v", err)
	}
	site, err := os.ReadFile(filepath.Join(root, "GEOSITE.dat"))
	if err != nil {
		t.Fatal(err)
	}
	sites, err := loader.LoadSiteByBytes(site, "cn")
	if err != nil || len(sites) == 0 {
		t.Fatalf("bundled GeoSite invalid: %v", err)
	}
	for _, name := range []string{"GEOIP.metadb", "ASN.mmdb"} {
		if !mmdb.Verify(filepath.Join(root, name)) {
			t.Fatalf("bundled %s invalid", name)
		}
	}
}
