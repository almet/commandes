port module Main exposing (..)

import Browser
import Browser.Dom exposing (focus)
import DateFormat exposing (french)
import Dict
import Html exposing (..)
import Html.Attributes exposing (attribute, class, colspan, id, list, placeholder, src, type_, value)
import Html.Events exposing (onClick, onInput, onSubmit)
import Json.Decode
import Json.Decode.Pipeline exposing (optional, required)
import Json.Encode
import Json.Encode.Extra
import List
import List.Extra
import Maybe.Extra exposing (isJust, join, values)
import Parser exposing ((|.), (|=), Parser, chompWhile, getChompedString, int, run, spaces, succeed, symbol)
import Random exposing (Seed, initialSeed, step)
import Stock
import String.Extra
import Task
import Time
import Time.Format
import Time.Format.Config.Config_fr_fr exposing (config)
import Uuid


type alias Model =
    { orderInput : String
    , customerInput : String
    , selectedCustomer : Maybe Customer
    , currentDate : Time.Posix
    , editedItemNumber : Maybe Int
    , currentOrder : Maybe Order
    , orders : List Order
    , customers : List Customer
    , serverPassword : Maybe String
    , serverPasswordInput : String
    , realStock : Stock.Stock
    , currentSeed : Seed
    , currentUuid : Maybe Uuid.Uuid
    , incomingBrews : List OrderLine
    , incomingBrewsInput : String
    }


type alias OrderLine =
    { quantity : Int
    , beer : Stock.StockItem
    }


type alias Order =
    { customer : Customer
    , lines : List OrderLine
    , date : Time.Posix
    , localId : Maybe Uuid.Uuid
    , remoteId : Maybe Int
    }


type alias OrderId =
    { localId : Uuid.Uuid
    , remoteId : Int
    }


type alias Customer =
    { id : Int
    , name : String
    }


type alias Flags =
    { encodedOrders : String
    , encodedPassword : String
    , encodedCustomers : String
    , encodedStock : String
    , encodedIncomingBrews : String
    , seed : Int
    }


noCustomer =
    Customer 0 "NO CUSTOMER"


init : Flags -> ( Model, Cmd Msg )
init flags =
    let
        customers =
            Json.Decode.decodeString customersDecoder flags.encodedCustomers
                |> Result.withDefault []

        orders =
            Json.Decode.decodeString ordersDecoder flags.encodedOrders
                |> Result.withDefault []

        stock =
            Stock.decodeStock flags.encodedStock

        incomingBrews =
            Json.Decode.decodeString (Json.Decode.list orderLineDecoder) flags.encodedIncomingBrews
                |> Result.withDefault []

        password =
            case flags.encodedPassword of
                "" ->
                    Nothing

                string ->
                    Just string
    in
    ( { orderInput = ""
      , editedItemNumber = Nothing
      , currentDate = Time.millisToPosix 0
      , currentOrder = Nothing
      , orders = orders
      , serverPassword = password
      , serverPasswordInput = ""
      , realStock = stock
      , customers = []
      , customerInput = ""
      , selectedCustomer = Nothing
      , currentSeed = initialSeed flags.seed
      , currentUuid = Nothing
      , incomingBrews = incomingBrews
      , incomingBrewsInput =
            incomingBrews
                |> orderLinesToString
      }
    , Cmd.batch
        [ retrieveCustomersFromServer ""
        , retrieveStockFromServer ""
        ]
    )



---- UPDATE ----


type Msg
    = UpdateInput String
    | UpdateCustomerInput String
    | SaveOrder
    | EditOrder Order Int
    | DeleteOrder Order Int
    | SyncOrder Order Int
    | ResetOrders
    | SaveServerPassword
    | UpdateServerPassword String
    | Tick Time.Posix
    | RetrieveStock
    | GotStockFromServer String
    | RetrieveCustomers
    | GotCustomersFromServer String
    | CreateOrdersOnServer
    | GotOrderIdFromServer String
    | UpdateIncomingBrews String
    | SaveIncomingBrews
    | NewUuid
    | NoOp


update : Msg -> Model -> ( Model, Cmd Msg )
update msg model =
    case msg of
        UpdateServerPassword content ->
            ( { model
                | serverPasswordInput = content
              }
            , Cmd.none
            )

        SaveServerPassword ->
            let
                password =
                    model.serverPasswordInput
            in
            ( { model
                | serverPassword = Just password
                , serverPasswordInput = ""
              }
            , storePassword password
            )

        UpdateIncomingBrews content ->
            ( { model | incomingBrewsInput = content }, Cmd.none )

        SaveIncomingBrews ->
            let
                brews =
                    parseItems (Just model.incomingBrewsInput) (model.realStock |> Dict.values |> List.concat)
            in
            ( { model | incomingBrews = brews }, storeIncomingBrews (Json.Encode.list encodeOrderLine brews) )

        UpdateInput content ->
            let
                ( newModel, cmd ) =
                    update NewUuid model

                customer =
                    newModel.selectedCustomer |> Maybe.withDefault noCustomer

                uuid =
                    case newModel.currentOrder of
                        Just o ->
                            case o.localId of
                                Just u ->
                                    Just u

                                Nothing ->
                                    newModel.currentUuid

                        Nothing ->
                            newModel.currentUuid

                order =
                    { customer = customer
                    , lines = parseItems (Just content) (newModel.realStock |> Dict.values |> List.concat)
                    , date = newModel.currentDate
                    , localId = uuid
                    , remoteId = Nothing
                    }
            in
            ( { newModel
                | currentOrder = Just order
                , orderInput = content
              }
            , cmd
            )

        UpdateCustomerInput content ->
            let
                selectedCustomer =
                    model.customers
                        |> List.filter (\a -> .name a == content)
                        |> List.head
            in
            ( { model
                | customerInput = content
                , selectedCustomer = selectedCustomer
              }
            , Cmd.none
            )

        ResetOrders ->
            ( { model | orders = [] }, storeOrders (encodeOrders []) )

        EditOrder order itemNumber ->
            let
                stringOrder =
                    orderLinesToString order.lines
            in
            update (UpdateInput stringOrder)
                { model
                    | orderInput = stringOrder
                    , editedItemNumber = Just itemNumber
                    , selectedCustomer = Just order.customer
                    , customerInput = order.customer.name
                }

        DeleteOrder order _ ->
            ( { model
                | orders = model.orders |> List.Extra.remove order
              }
            , Cmd.none
            )

        SyncOrder order _ ->
            ( model, createOrdersOnServer (encodeOrders [ order ]) )

        SaveOrder ->
            case model.currentOrder of
                Just order ->
                    let
                        newOrder =
                            { order | date = model.currentDate }

                        orders =
                            case model.editedItemNumber of
                                Just int ->
                                    List.Extra.setAt int newOrder model.orders

                                Nothing ->
                                    model.orders ++ [ newOrder ]
                    in
                    ( { model
                        | orders = orders
                        , currentOrder = Nothing
                        , orderInput = ""
                        , editedItemNumber = Nothing
                        , selectedCustomer = Nothing
                        , customerInput = ""
                      }
                    , Cmd.batch [ storeOrders (encodeOrders orders), Task.attempt (\_ -> NoOp) (focus "customer") ]
                    )

                Nothing ->
                    ( model, Cmd.none )

        Tick date ->
            ( { model | currentDate = date }, Cmd.none )

        RetrieveStock ->
            ( model, retrieveStockFromServer "" )

        RetrieveCustomers ->
            ( model, retrieveCustomersFromServer "" )

        GotStockFromServer encodedStock ->
            let
                stock =
                    Stock.decodeFromServer encodedStock
            in
            ( { model | realStock = stock }, storeStock (Stock.encodeStock stock) )

        GotCustomersFromServer encodedCustomers ->
            let
                customers =
                    Json.Decode.decodeString customersDecoder encodedCustomers |> Result.withDefault []
            in
            ( { model | customers = customers }, storeCustomers (encodeCustomers customers) )

        CreateOrdersOnServer ->
            ( model, createOrdersOnServer (encodeOrders model.orders) )

        GotOrderIdFromServer encodedOrderId ->
            let
                newModel =
                    case Json.Decode.decodeString orderIdDecoder encodedOrderId of
                        Ok orderId ->
                            { model
                                | orders =
                                    model.orders
                                        |> List.Extra.filterNot
                                            (\item -> item.localId == Just orderId.localId)
                            }

                        Err e ->
                            model
            in
            ( newModel, storeOrders (encodeOrders newModel.orders) )

        NewUuid ->
            let
                ( newUuid, newSeed ) =
                    step Uuid.uuidGenerator model.currentSeed
            in
            -- 2.: Store the new seed
            ( { model
                | currentUuid = Just newUuid
                , currentSeed = newSeed
              }
            , Cmd.none
            )

        NoOp ->
            ( model, Cmd.none )


parseItems : Maybe String -> List Stock.StockItem -> List OrderLine
parseItems text availableItems =
    case text of
        Nothing ->
            []

        Just string ->
            String.split "," string
                |> List.map String.trim
                |> List.map (toOrderLine availableItems)
                |> List.filterMap identity
                |> addExtraOrderLines


addExtraOrderLines : List OrderLine -> List OrderLine
addExtraOrderLines sourceLines =
    let
        kegs =
            List.filter (\line -> line.beer.format == Stock.Keg20L) sourceLines
                |> List.map (\line -> line.quantity)
                |> List.sum
    in
    if kegs > 0 then
        { quantity = kegs, beer = Stock.depositKeg } :: sourceLines

    else
        sourceLines


toOrderLine : List Stock.StockItem -> String -> Maybe OrderLine
toOrderLine stockItems query =
    let
        stockItem =
            List.Extra.find (\x -> String.contains x.code query) stockItems

        quantity =
            case stockItem of
                Just a ->
                    String.Extra.leftOf a.code query
                        |> String.toInt
                        |> Maybe.withDefault 0
                        |> Stock.convertToUnits a.format

                Nothing ->
                    0
    in
    if Maybe.Extra.isJust stockItem && (quantity > 0) then
        Just
            { quantity = quantity
            , beer =
                stockItem
                    |> Maybe.withDefault Stock.nullStockItem
            }

    else
        Nothing


orderLinesToString : List OrderLine -> String
orderLinesToString lines =
    String.join ", " <|
        List.map
            (\line ->
                (Stock.convertToBoxes line.beer.format line.quantity
                    |> String.fromInt
                )
                    ++ line.beer.code
            )
            (lines |> List.filter (\line -> line.beer.format /= Stock.NoFormat))


getCurrentStock : (Int -> Int -> Int) -> Stock.Stock -> List OrderLine -> Stock.Stock
getCurrentStock operation realStock lines =
    lines
        |> List.foldl (reduceStock operation) realStock


reduceStock : (Int -> Int -> Int) -> OrderLine -> Stock.Stock -> Stock.Stock
reduceStock operation line stock =
    let
        beerName =
            line.beer.name

        updateStockItem item =
            if item.code == line.beer.code then
                { item | available = operation item.available line.quantity }

            else
                item

        updateStockItemList list =
            case list of
                Just source ->
                    Just (List.map updateStockItem source)

                Nothing ->
                    Nothing
    in
    Dict.update line.beer.name updateStockItemList stock


viewOrder : Int -> Order -> Html Msg
viewOrder itemNumber order =
    let
        viewOrderLine line =
            String.fromInt line.quantity
                ++ " × "
                ++ line.beer.name
                ++ " "
                ++ Stock.formatToString line.beer.format

        viewLi line =
            li [] [ viewOrderLine line |> text ]

        lines =
            order.lines
                |> List.filter (\line -> line.beer.format /= Stock.NoFormat)
    in
    div
        [ class "card" ]
        [ header
            [ class "card-header" ]
            [ p
                [ class "card-header-title" ]
                [ let
                    date =
                        DateFormat.formatI18n french "dd MMMM" Time.utc order.date

                    name =
                        case order.remoteId of
                            Just int ->
                                "⇋ " ++ order.customer.name

                            Nothing ->
                                order.customer.name
                  in
                  name ++ " (" ++ date ++ ") " |> text
                ]
            ]
        , div
            [ class "card-content" ]
            [ div
                [ class "content" ]
                [ ul [ class "order" ] (List.map viewLi lines)
                ]
            ]
        , footer
            [ class "card-footer" ]
            [ a [ class "card-footer-item", onClick (SyncOrder order itemNumber) ] [ text "sync" ]
            , a [ class "card-footer-item", onClick (DeleteOrder order itemNumber) ] [ text "delete" ]
            ]
        ]


view : Model -> Html Msg
view model =
    case model.serverPassword of
        Just string ->
            mainView model

        Nothing ->
            enterPasswordView model


enterPasswordView : Model -> Html Msg
enterPasswordView model =
    div []
        [ form [ onSubmit SaveServerPassword ]
            [ input [ placeholder "Merci de rentrer le code d'accès a Odoo", onInput UpdateServerPassword, value model.serverPasswordInput ] []
            ]
        ]


mainView : Model -> Html Msg
mainView model =
    div [ class "section" ]
        [ div [ class "container" ]
            [ nav [ class "level" ]
                [ div [ class "level-left" ]
                    [ div [ class "level-item" ]
                        []
                    ]
                ]
            , div [ class "columns" ]
                [ form [ id "order-form", onSubmit SaveOrder ]
                    [ div [ class "column is-one-third" ] [ customerInputView model ]
                    , div [ class "column" ]
                        [ input
                            [ placeholder "Commande ici, par ex \"10ST20, 3NM75\""
                            , class "order-input"
                            , onInput UpdateInput
                            , value model.orderInput
                            ]
                            []
                        , button [ class "submit" ] []
                        ]
                    ]
                ]
            , div [ class "columns" ]
                [ div [ class "column" ]
                    [ viewCurrentOrder model.currentOrder model.selectedCustomer
                    , viewOrders model.orders
                    ]
                ]
            ]
        ]


viewCurrentOrder : Maybe Order -> Maybe Customer -> Html Msg
viewCurrentOrder order customer =
    let
        viewOrderLine line =
            String.fromInt line.quantity
                ++ " × "
                ++ line.beer.name
                ++ " "
                ++ Stock.formatToString line.beer.format

        item =
            case order of
                Just o ->
                    case o.lines of
                        [] ->
                            case customer of
                                Just c ->
                                    text c.name

                                Nothing ->
                                    text "?"

                        lines ->
                            let
                                orders =
                                    List.map viewOrderLine lines
                                        |> List.intersperse ", "
                                        |> String.concat
                            in
                            o.customer.name ++ " : " ++ orders |> text

                Nothing ->
                    text "⠀"
    in
    div [ class "current-order" ]
        [ item
        ]


viewOrders : List Order -> Html Msg
viewOrders orders =
    case orders of
        [] ->
            p [] []

        items ->
            ul [ class "orders" ] (List.indexedMap viewOrder orders)


customerInputView : Model -> Html Msg
customerInputView model =
    let
        getOption customer =
            option [ value customer.name ] [ customer.name |> text ]
    in
    div []
        [ input
            [ id "customer"
            , placeholder "Client"
            , list "customers"
            , class "customer-input"
            , onInput UpdateCustomerInput
            , value model.customerInput
            ]
            []
        , datalist [ id "customers" ] (List.map getOption model.customers)
        ]



---- Subscriptions


subscriptions : Model -> Sub Msg
subscriptions model =
    Sub.batch
        [ Time.every (30 * 1000) Tick
        , gotStockFromServer GotStockFromServer
        , gotCustomersFromServer GotCustomersFromServer
        , gotOrderIdFromServer GotOrderIdFromServer
        , Time.every (30 * 1000) (\_ -> RetrieveCustomers)
        ]



---- Encoders & Decoders ----


encodeOrders : List Order -> Json.Encode.Value
encodeOrders orders =
    Json.Encode.list encodeOrder orders


encodeOrder : Order -> Json.Encode.Value
encodeOrder order =
    Json.Encode.object
        [ ( "customer", encodeCustomer order.customer )
        , ( "orders", Json.Encode.list encodeOrderLine order.lines )
        , ( "date", order.date |> Time.posixToMillis |> Json.Encode.int )
        , ( "localId", order.localId |> Json.Encode.Extra.maybe Uuid.encode )
        , ( "remoteId", order.remoteId |> Json.Encode.Extra.maybe Json.Encode.int )
        ]


encodeOrderLine : OrderLine -> Json.Encode.Value
encodeOrderLine orderLine =
    Json.Encode.object
        [ ( "quantity", Json.Encode.int orderLine.quantity )
        , ( "beer", Stock.encodeStockItemData orderLine.beer )
        ]


ordersDecoder : Json.Decode.Decoder (List Order)
ordersDecoder =
    Json.Decode.list orderDecoder


orderDecoder : Json.Decode.Decoder Order
orderDecoder =
    Json.Decode.succeed Order
        |> required "customer" customerDecoder
        |> required "orders" (Json.Decode.list orderLineDecoder)
        |> required "date" (Json.Decode.map Time.millisToPosix Json.Decode.int)
        |> optional "localId" (Json.Decode.map Just Uuid.decoder) Nothing
        |> optional "remoteId" (Json.Decode.map Just Json.Decode.int) Nothing


orderIdDecoder : Json.Decode.Decoder OrderId
orderIdDecoder =
    Json.Decode.succeed OrderId
        |> required "localId" Uuid.decoder
        |> required "remoteId" Json.Decode.int


orderLineDecoder : Json.Decode.Decoder OrderLine
orderLineDecoder =
    Json.Decode.succeed OrderLine
        |> required "quantity" Json.Decode.int
        |> required "beer" Stock.stockItemDecoder


customersDecoder : Json.Decode.Decoder (List Customer)
customersDecoder =
    Json.Decode.list customerDecoder


customerDecoder : Json.Decode.Decoder Customer
customerDecoder =
    Json.Decode.succeed Customer
        |> required "id" Json.Decode.int
        |> required "name" Json.Decode.string


encodeCustomers : List Customer -> Json.Encode.Value
encodeCustomers customers =
    Json.Encode.list encodeCustomer customers


encodeCustomer : Customer -> Json.Encode.Value
encodeCustomer customer =
    Json.Encode.object
        [ ( "id", Json.Encode.int customer.id )
        , ( "name", Json.Encode.string customer.name )
        ]


port storeOrders : Json.Encode.Value -> Cmd msg


port storeCustomers : Json.Encode.Value -> Cmd msg


port storeStock : Json.Encode.Value -> Cmd msg


port storePassword : String -> Cmd msg


port storeIncomingBrews : Json.Encode.Value -> Cmd msg


port retrieveStockFromServer : String -> Cmd msg


port retrieveCustomersFromServer : String -> Cmd msg


port gotStockFromServer : (String -> msg) -> Sub msg


port gotCustomersFromServer : (String -> msg) -> Sub msg


port createOrdersOnServer : Json.Encode.Value -> Cmd msg


port gotOrderIdFromServer : (String -> msg) -> Sub msg



---- PROGRAM ----


main : Program Flags Model Msg
main =
    Browser.element
        { view = view
        , init = init
        , update = update
        , subscriptions = subscriptions
        }
