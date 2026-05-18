package org.acme;

import io.quarkus.hibernate.orm.panache.PanacheEntity;
import jakarta.persistence.Column;
import jakarta.persistence.Entity;

@Entity
public class Product extends PanacheEntity {
    public String name;

    @Column(unique = true)
    public String sku;

    public double price;

    public static Product bySku(String sku) {
        return find("sku", sku).firstResult();
    }
}
