var dbs = ["workout-management", "COACHIFY", "users"];
dbs.forEach(function(dbName) {
    print("\n=== DB: " + dbName + " ===");
    var d = db.getSiblingDB(dbName);
    var cols = d.getCollectionNames();
    cols.forEach(function(c) {
        var ix = d[c].getIndexes();
        print(c + " [" + ix.length + " idx]:");
        ix.forEach(function(i) { print("  " + JSON.stringify(i.key)); });
    });
});
