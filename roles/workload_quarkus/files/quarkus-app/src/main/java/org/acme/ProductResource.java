package org.acme;

import jakarta.transaction.Transactional;
import jakarta.ws.rs.GET;
import jakarta.ws.rs.NotFoundException;
import jakarta.ws.rs.Path;
import jakarta.ws.rs.PathParam;
import jakarta.ws.rs.Produces;
import jakarta.ws.rs.core.MediaType;
import java.util.List;
import java.util.Map;

@Path("/api")
@Produces(MediaType.APPLICATION_JSON)
public class ProductResource {

    // DB query span (Hibernate/JDBC auto-instrumented via
    // quarkus.datasource.jdbc.telemetry) nested under the REST server span.
    @GET
    @Path("/products")
    public List<Product> products() {
        return Product.listAll();
    }

    // Called cross-namespace by the Python app's /checkout chain. Two DB
    // lookups so the trace shows a deeper span tree.
    @GET
    @Path("/price/{sku}")
    public Map<String, Object> price(@PathParam("sku") String sku) {
        Product p = Product.bySku(sku);
        if (p == null) {
            throw new NotFoundException("no such sku: " + sku);
        }
        long catalogSize = Product.count();
        return Map.of("sku", p.sku, "name", p.name,
                      "price", p.price, "catalogSize", catalogSize);
    }

    // Deliberate failure so tail_sampling's keep-errors policy has an
    // ERROR-status span to retain (HTTP 404 alone is not a span error).
    @GET
    @Path("/boom")
    @Transactional
    public String boom() {
        throw new RuntimeException("intentional failure for tracing demo");
    }
}
