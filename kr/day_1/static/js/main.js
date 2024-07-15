function get_customer() {
    fetch("/v1/customer?id=" + document.getElementById("ct_id").value)
        .then((response) => response.json())
	    .then((json) => document.getElementById("get_customer").textContent = JSON.stringify(json));
}

function post_customer() {
    fetch("/v1/customer", {
        method : "POST",
        headers : {"Content-Type": "application/json",},
        body: JSON.stringify({
            id: document.getElementById("customer_id").value,
            name: document.getElementById("customer_name").value,
            gender: document.getElementById("customer_gender").value,
        }),
    })
        .then((response) => response.json())
	    .then((json) => document.getElementById("post_customer").textContent = JSON.stringify(json));
}

function get_product() {
    fetch("/v1/product?id=" + document.getElementById("pd_id").value)
        .then((response) => response.json())
	    .then((json) => document.getElementById("get_product").textContent = JSON.stringify(json));
}

function post_product() {
    fetch("/v1/product", {
        method : "POST",
        headers : {"Content-Type": "application/json",},
        body: JSON.stringify({
            id: document.getElementById("product_id").value,
            name: document.getElementById("product_name").value,
            category: document.getElementById("product_category").value,
        }),
    })
        .then((response) => response.json())
	    .then((json) => document.getElementById("post_product").textContent = JSON.stringify(json));
}

function get_order() {
    fetch("/v1/order?id=" + document.getElementById("od_id").value)
        .then((response) => response.json())
        .then((json) => document.getElementById("get_order").textContent = JSON.stringify(json));
}

function post_order() {
    fetch("/v1/order", {
        method : "POST",
        headers : {"Content-Type": "application/json",},
        body: JSON.stringify({
            id: document.getElementById("order_id").value,
            customerid: document.getElementById("order_cid").value,
            productid: document.getElementById("order_pid").value,
        }),
    })
        .then((response) => response.json())
	    .then((json) => document.getElementById("post_order").textContent = JSON.stringify(json));
}