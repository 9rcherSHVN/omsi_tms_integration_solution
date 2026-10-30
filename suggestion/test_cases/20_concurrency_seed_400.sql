SET NOCOUNT ON; DECLARE @i int = 0, @p nvarchar(max), @k nvarchar(20);
WHILE @i < 400 BEGIN
  SET @k = CONVERT(nvarchar(20), 7000000 + @i);
  SET @p = CONCAT(N'{"shipmentNumber":', @k, N',"weightUom":"LB","stops":[{"seq":1,"isPickup":1},{"seq":2,"isPickup":0}]}');
  EXEC integ.usp_Outbox_Publish @EntityType='Shipment', @SourceKey=@k, @EventType='ShipmentReady', @NewState='Ready', @PayloadJson=@p;
  SET @i += 1; END;
