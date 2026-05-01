import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mobile_app/main.dart';

void main() {
  testWidgets('renders server picker shell', (tester) async {
    await tester.pumpWidget(const GScaleMobileApp());

    expect(find.text('gscale-zebra'), findsOneWidget);
    expect(find.byIcon(Icons.add_link_rounded), findsOneWidget);
  });

  test('parses batch print mode from payloads', () {
    final batch = MobileBatchState.fromJson(const {
      'active': true,
      'item_code': 'ITEM-001',
      'item_name': 'Green Tea',
      'warehouse': 'Stores - A',
      'print_mode': 'label',
      'printer': 'g500',
      'quantity_source': 'manual',
      'manual_qty_kg': 5.25,
      'tare': true,
      'tare_kg': 0.78,
    });
    expect(batch.printMode, 'label');
    expect(batch.printer, 'godex');
    expect(batch.displayPrinter, 'GoDEX');
    expect(batch.quantitySource, 'manual');
    expect(batch.manualQtyKg, 5.25);
    expect(batch.tareEnabled, isTrue);
    expect(batch.tareKg, 0.78);

    final snapshot = MonitorSnapshot.fromJson(const {
      'ok': true,
      'state': {
        'batch': {
          'active': true,
          'item_code': 'ITEM-001',
          'item_name': 'Green Tea',
          'warehouse': 'Stores - A',
          'print_mode': 'label',
          'printer': 'godex',
          'quantity_source': 'manual',
          'manual_qty_kg': 5.25,
          'tare': true,
          'tare_kg': 0.78,
        },
      },
      'printer': {'ok': false},
    });
    expect(snapshot.batchPrintMode, 'label');
    expect(snapshot.batchPrinter, 'godex');
    expect(snapshot.batchQuantitySource, 'manual');
    expect(snapshot.batchManualQtyKg, 5.25);
    expect(snapshot.batchTareEnabled, isTrue);
    expect(snapshot.batchTareKg, 0.78);
  });

  test('manual print helper disables blank and undersized values', () {
    expect(
      canTriggerManualPrint(qtyText: '', babinaEnabled: false, babinaText: ''),
      isFalse,
    );
    expect(
      canTriggerManualPrint(
        qtyText: '0.05',
        babinaEnabled: false,
        babinaText: '',
      ),
      isFalse,
    );
    expect(
      canTriggerManualPrint(
        qtyText: '0.78',
        babinaEnabled: true,
        babinaText: '0.78',
      ),
      isFalse,
    );
    expect(
      canTriggerManualPrint(
        qtyText: '5',
        babinaEnabled: true,
        babinaText: '0.78',
      ),
      isTrue,
    );
  });
}
