// GENERATED CODE - DO NOT MODIFY BY HAND
// dart format width=80

part of 'bookstore.dart';

// **************************************************************************
// RecordGenerator
// **************************************************************************

class _$AuthorInit {
  _$AuthorInit() {
    final fields = <String, Object? Function(Author)>{};
    fields['id'] = (a) => a.id;
    fields['name'] = (a) => a.name;
    fields['country'] = (a) => a.country;
    Record.register<Author>(fields);
  }
}

final _authorInit = _$AuthorInit();

/// Registers the [Author] field accessors with d_rocket's
/// internal registry. Called by `d_rocket_registry.g.dart`'s
/// `initializeD()` at application startup.
void registerAuthorRecord() {
  _authorInit;
}

class _$BookInit {
  _$BookInit() {
    final fields = <String, Object? Function(Book)>{};
    fields['id'] = (a) => a.id;
    fields['title'] = (a) => a.title;
    fields['authorId'] = (a) => a.authorId;
    fields['year'] = (a) => a.year;
    fields['price'] = (a) => a.price;
    fields['category'] = (a) => a.category;
    Record.register<Book>(fields);
  }
}

final _bookInit = _$BookInit();

/// Registers the [Book] field accessors with d_rocket's
/// internal registry. Called by `d_rocket_registry.g.dart`'s
/// `initializeD()` at application startup.
void registerBookRecord() {
  _bookInit;
}

class _$SaleInit {
  _$SaleInit() {
    final fields = <String, Object? Function(Sale)>{};
    fields['id'] = (a) => a.id;
    fields['bookId'] = (a) => a.bookId;
    fields['customer'] = (a) => a.customer;
    fields['quantity'] = (a) => a.quantity;
    fields['totalPrice'] = (a) => a.totalPrice;
    fields['date'] = (a) => a.date;
    Record.register<Sale>(fields);
  }
}

final _saleInit = _$SaleInit();

/// Registers the [Sale] field accessors with d_rocket's
/// internal registry. Called by `d_rocket_registry.g.dart`'s
/// `initializeD()` at application startup.
void registerSaleRecord() {
  _saleInit;
}
