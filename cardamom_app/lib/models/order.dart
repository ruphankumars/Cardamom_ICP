class Order {
  final String? orderDate;
  final String? billingFrom;
  final String? client;
  final String? lot;
  final String? grade;
  final String? bagbox;
  final num? no;
  final num? kgs;
  final num? price;
  final String? brand;
  final String? status;
  final String? notes;
  final int? rowIndex;

  Order({
    this.orderDate,
    this.billingFrom,
    this.client,
    this.lot,
    this.grade,
    this.bagbox,
    this.no,
    this.kgs,
    this.price,
    this.brand,
    this.status,
    this.notes,
    this.rowIndex,
  });

  factory Order.fromJson(Map<String, dynamic> json) {
    return Order(
      orderDate: json['orderDate']?.toString(),
      billingFrom: json['billingFrom']?.toString(),
      client: json['client']?.toString(),
      lot: json['lot']?.toString(),
      grade: json['grade']?.toString(),
      bagbox: json['bagbox']?.toString(),
      no: json['no'] != null ? num.tryParse(json['no'].toString()) : null,
      kgs: json['kgs'] != null ? num.tryParse(json['kgs'].toString()) : null,
      price: json['price'] != null ? num.tryParse(json['price'].toString()) : null,
      brand: json['brand']?.toString(),
      status: json['status']?.toString(),
      notes: json['notes']?.toString(),
      rowIndex: json['rowIndex'] is int ? json['rowIndex'] : int.tryParse(json['rowIndex']?.toString() ?? ''),
    );
  }

  factory Order.fromRow(List<dynamic> row, Map<String, int> columnMap) {
    T? _get<T>(int index) => index < row.length ? row[index] as T? : null;
    dynamic _val(String key, int fallback) => _get(columnMap[key] ?? fallback);
    return Order(
      orderDate: _val('orderDate', 0)?.toString(),
      billingFrom: _val('billingFrom', 1)?.toString(),
      client: _val('client', 2)?.toString(),
      lot: _val('lot', 3)?.toString(),
      grade: _val('grade', 4)?.toString(),
      bagbox: _val('bagbox', 5)?.toString(),
      no: _val('no', 6) != null ? num.tryParse(_val('no', 6).toString()) : null,
      kgs: _val('kgs', 7) != null ? num.tryParse(_val('kgs', 7).toString()) : null,
      price: _val('price', 8) != null ? num.tryParse(_val('price', 8).toString()) : null,
      brand: _val('brand', 9)?.toString(),
      status: _val('status', 10)?.toString(),
      notes: _val('notes', 11)?.toString(),
    );
  }

  Map<String, dynamic> toJson() {
    return {
      'orderDate': orderDate,
      'billingFrom': billingFrom,
      'client': client,
      'lot': lot,
      'grade': grade,
      'bagbox': bagbox,
      'no': no,
      'kgs': kgs,
      'price': price,
      'brand': brand,
      'status': status,
      'notes': notes,
    };
  }
}





